require 'puppet'
require 'puppet/functions'

require 'json'
require 'net/http'
require 'uri'

Puppet::Functions.create_function(:hiera_aws_secretsmanager) do
  # An implementation of a lookup_key Puppet Function for Hiera.
  # Looks up keys in AWS Secrets Manager via the local Secrets Manager Agent.
  #
  # Supports multi-account lookups. Keys can be prefixed with an account
  # name using the separator ':-', e.g. 'staging:-mymod::myclass::password'.
  # Account names are resolved to a role_arn via the 'accounts' option
  # in hiera.yaml. The agent assumes the given IAM role for cross-account
  # access. Keys without a prefix use the 'default_account' option.
  #
  # @param key Hiera key, e.g. `mydb::myuser::mypassword` or
  #   `staging:-mydb::myuser::mypassword`
  #
  # @option options 'uri' contains an interpolated value from the uris
  # list in hiera.yaml. Puppet handles iterating over all possible
  # interpolations for us.
  #
  # @param context A Puppet::LookupContext passed from Puppet
  dispatch :lookup_key do
    param 'String', :key
    param 'Hash', :options
    param 'Any', :context
  end

  # Lame explicit check for already defined constants courtesy of
  # Puppet feeling the need to reload this file over and over.
  unless defined? ACCOUNT_SEPARATOR
    ACCOUNT_SEPARATOR = ':-'.freeze
    AGENT_DEFAULT_HOST = 'localhost'.freeze
    AGENT_DEFAULT_PORT = 2773
    SSRF_HEADER = 'X-Aws-Parameters-Secrets-Token'.freeze
  end

  def lookup_key(key, options, context)
    @context = context
    @options = options

    unless options.include? 'uri'
      raise ArgumentError, "either 'uri' or 'uris' must be set in hiera.yaml"
    end

    account_name, secret_key = parse_account_and_key(key)

    # Secrets Manager does not allow ':' in secret names, so we
    # translate them here. We choose '=' merely because it is
    # graphically similar to ':'.
    secret_key = secret_key.dup.tr(':', '=')

    secret_path = "#{options['uri']}/#{secret_key}"
    role_arn = resolve_role_arn(account_name)

    @context.explain { "Resolving secret: #{secret_path} (account: #{account_name || 'local'})" }

    fetch_secret(secret_path, role_arn)
  end

  private

  def parse_account_and_key(key)
    if key.include?(ACCOUNT_SEPARATOR)
      parts = key.split(ACCOUNT_SEPARATOR, 2)
      [parts[0], parts[1]]
    elsif @options['default_account']
      [@options['default_account'], key]
    else
      [nil, key]
    end
  end

  def resolve_role_arn(account_name)
    return nil unless account_name

    accounts = @options['accounts']
    unless accounts && accounts.key?(account_name)
      raise ArgumentError, "account '#{account_name}' not found in options.accounts configuration"
    end

    account_config = accounts[account_name]
    role_arn = account_config['role_arn']

    unless role_arn
      raise ArgumentError, "role_arn not set for account '#{account_name}' in options.accounts"
    end

    role_arn
  end

  def fetch_secret(secret_path, role_arn = nil)
    response = fetch_secret_from_agent(secret_path, role_arn)

    unless response.is_a?(Net::HTTPSuccess)
      @context.explain { "Secret not found or agent error: #{secret_path} (HTTP #{response.code})" }
      return @context.not_found
    end

    @context.explain { "Found secret: #{secret_path}" }

    secret_string = parse_agent_response(response.body)
    interpolated_string = @context.interpolate(secret_string)

    secret_object = JSON.parse(interpolated_string)

    @context.explain { "Secret parsed as JSON:\n#{secret_object.inspect}" }
    secret_object
  end

  def parse_agent_response(body)
    parsed = JSON.parse(body)
    if parsed.is_a?(Hash) && parsed.key?('SecretString')
      parsed['SecretString']
    else
      body
    end
  rescue JSON::ParserError
    body
  end

  def fetch_secret_from_agent(secret_path, role_arn = nil)
    host = @options['agent_host'] || AGENT_DEFAULT_HOST
    port = (@options['agent_port'] || AGENT_DEFAULT_PORT).to_i
    token = ssrf_token

    params = { 'secretId' => secret_path }
    params['roleArn'] = role_arn if role_arn

    uri = URI("http://#{host}:#{port}/secretsmanager/get")
    uri.query = URI.encode_www_form(params)

    request = Net::HTTP::Get.new(uri)
    request[SSRF_HEADER] = token if token

    Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(request)
    end
  end

  def ssrf_token
    env_var = @options['ssrf_env_var']
    return nil unless env_var

    token = ENV[env_var]
    unless token && !token.empty?
      raise ArgumentError, "SSRF token environment variable '#{env_var}' is not set or empty"
    end
    token
  end
end
