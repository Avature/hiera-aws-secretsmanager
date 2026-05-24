# hiera_aws_secretsmanager

#### Table of Contents

1. [Description](#description)
1. [Setup](#setup)
    * [Setup requirements](#setup-requirements)
    * [Installation](#installation)
    * [AWS Secrets Manager Agent](#aws-secrets-manager-agent)
    * [Authentication & Authorization](#authentication--authorization)
1. [Usage](#usage)
    * [Configuration](#configuration)
    * [Multi-Account Support](#multi-account-support)
    * [Convention](#convention)
    * [Notes](#notes)
1. [Limitations](#limitations)

## Description

An opinionated Hiera 5 `lookup_key` function for AWS Secrets Manager.
Fetches secrets via the local [AWS Secrets Manager Agent] daemon,
with support for multi-account lookups using IAM role assumption.

[AWS Secrets Manager Agent]: https://github.com/aws/aws-secretsmanager-agent

## Setup

### Setup Requirements

No Ruby gems are required. This module uses the Ruby standard library
(`net/http`) to communicate with the locally running AWS Secrets
Manager Agent.

### Installation

You can either clone this repository and include it in your puppet
modules (named as `hiera_aws_secretsmanager`), or if you are using
r10k, add it to your puppetfile as:

```
mod 'hiera_aws_secretsmanager',
    :git => 'https://github.com/krux/hiera-aws-secretsmanager',
    :tag => 'v0.4.0'
```

### AWS Secrets Manager Agent

The [AWS Secrets Manager Agent] must be installed and running on the
Puppet server. It acts as a local HTTP proxy that caches and serves
secrets from AWS Secrets Manager.

See the [agent documentation](https://github.com/aws/aws-secretsmanager-agent/blob/main/README.md)
for installation and configuration instructions.

The agent listens on `localhost:2773` by default and requires an SSRF
token for authentication.

### Authentication & Authorization

Authentication is handled by the AWS Secrets Manager Agent, which uses
the standard AWS credential chain (instance profile, environment
variables, `~/.aws/credentials`, etc).

For **same-account** secrets, the agent's IAM role needs:

``` json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPuppetSecrets",
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:*:*:secret:puppet/*"
    }
  ]
}
```

For **cross-account** secrets, the agent assumes an IAM role in the
target account via the `roleArn` query parameter. You need:

1. A role in the target account that allows reading the secrets:

``` json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPuppetSecrets",
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:*:*:secret:puppet/*"
    }
  ]
}
```

2. A trust policy on that role allowing the agent's IAM role to
   assume it:

``` json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCrossAccountAssume",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::AGENT_ACCOUNT_ID:role/AGENT_ROLE_NAME"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

3. The agent's own IAM role must be allowed to call `sts:AssumeRole`
   on the target role.

## Usage

### Configuration

Add to `hiera.yaml`:

``` yaml
---
version: 5

hierarchy:
  - name: AWS Secrets Manager
    lookup_key: hiera_aws_secretsmanager
    uris:
      - "secrets/%{::environment}"
    options:
      agent_port: 2773            # optional, default 2773
      agent_host: localhost        # optional, default localhost
      ssrf_env_var: AWS_TOKEN      # env var containing the SSRF token
      default_account: main        # optional, fallback for unprefixed keys
      accounts:
        main:
          role_arn: "arn:aws:iam::123456789012:role/PuppetSecretsRole"
        staging:
          role_arn: "arn:aws:iam::987654321098:role/PuppetSecretsRole"
```

#### Options Reference

| Option | Required | Default | Description |
|---|---|---|---|
| `agent_host` | no | `localhost` | Hostname of the Secrets Manager Agent |
| `agent_port` | no | `2773` | Port of the Secrets Manager Agent |
| `ssrf_env_var` | no | - | Environment variable name containing the SSRF token |
| `default_account` | no | - | Account name to use when keys have no prefix |
| `accounts` | no | - | Map of account names to account configuration |

Each entry under `accounts` supports:

| Key | Required | Description |
|---|---|---|
| `role_arn` | yes | IAM role ARN for the agent to assume in the target account |

### Multi-Account Support

Keys can be prefixed with an account name using the `:-` separator:

```
<account-name>:-<puppet-key>
```

**Examples:**

``` puppet
# Looks up from the 'staging' account
lookup('staging:-myapp::database::password')

# Looks up from the default account (if default_account is set)
lookup('myapp::database::password')
```

The plugin resolves the account name to a `role_arn` from the
`accounts` configuration and passes it as a query parameter to the
AWS Secrets Manager Agent. The agent assumes the given IAM role
to fetch the secret from the target account.

If no account prefix is given and `default_account` is set, the
default account's `role_arn` is used. If `default_account` is not
set, the request is made without a `roleArn` (same-account lookup).

### Convention

#### Storing Secrets as JSON

The AWS Console and provided examples for rotation are both heavy on
JSON. This backend therefore assumes that the `secret_string` member
of your secret is always a valid JSON document, and that you want it
parsed. Conforming with RFC 7159, below are examples of valid strings
for the `SecretString` member:

``` json
"seekrit"

42

false

null

{ "username": "sooper", "password": "seekrit" }

[ 1, 2, 3 ]
```

Unquoted strings that are not values (like `true`) are not valid and
will raise a parse error. Be aware of the need for quoting in certain
contexts. E.g.

``` ruby
new_secret = "a string"
client.update_secret(secret_id: 'puppet/production/secret_key', secret_string: "\"#{new_secret}\"")
```
although much better in this instance would be
``` ruby
client.update_secret(secret_id: 'puppet/production/secret_key', secret_string: new_secret.to_json)
```

#### Character Translation In Secret Names

AWS Secrets Manager does not allow `:` in secret names. In order to
accommodate the Puppet convention of `module::class::parameter`, the
key portion (after stripping the account prefix) has `:` replaced by
`=` before being looked up. Unfortunately this means humans managing
secrets will have to do this translation in wetware.

For a concrete example, assume a class definition like:

``` puppet
# module mymod
class myclass (
  String username,
  String password,
)
```

We would probably like to find `username` in our favorite Hiera
backend (let's just say YAML), and `password` in our secret
store. We can set this up with:

**data/environment/production/common.yaml:**
``` yaml
mymod::myclass::username: the_user
```

**tmp/secret.json:**
``` json
"the_password"
```

**create the secret:**
``` shell
aws secretsmanager create-secret --name puppet/production/mymod==myclass==password --secret-string file://tmp/secret.json
```

### Notes

1. Paths in Secrets Manager may not have a leading `/`.
1. URIs in the hiera configuration must not have a trailing `/`.
1. The AWS Secrets Manager Agent must be running and accessible.
1. The SSRF token environment variable must be available in the
   Puppet process's environment when `ssrf_env_var` is configured.

### Caching

Caching is handled entirely by the AWS Secrets Manager Agent. Each
lookup contacts the agent, which serves secrets from its local cache
when possible. See the [agent documentation](https://github.com/aws/aws-secretsmanager-agent/blob/main/README.md)
for cache TTL and configuration options.

## Limitations

Only returns `secret_string`, which is unconditionally parsed as
JSON. There is no way to return `secret_binary` or any other attribute
from the secret, nor skip JSON parsing.

Secret names are unconditionally translated to replace `:` with `=`.
The `=` was chosen merely for visual similarity to `:` and is not
configurable.

