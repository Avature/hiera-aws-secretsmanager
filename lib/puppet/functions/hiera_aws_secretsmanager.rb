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
  # Account names are resolved to AWS account IDs via the 'accounts' option
  # in hiera.yaml. Keys without a prefix use the 'default_account' option.
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

    unless options.key? 'region'
      raise ArgumentError, 'options: {region: ...} must be set in hiera.yaml'
    end

    account_name, secret_key = parse_account_and_key(key)

    # Secrets Manager does not allow ':' in secret names, so we
    # translate them here. We choose '=' merely because it is
    # graphically similar to ':'.
    secret_key = secret_key.dup.tr(':', '=')

    secret_path = "#{options['uri']}/#{secret_key}"
    secret_id = resolve_secret_id(account_name, secret_path)

    @context.explain { "Resolving secret: #{secret_id} (account: #{account_name || 'local'})" }

    cached_or_fetch_secret(secret_id)
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

  def resolve_secret_id(account_name, secret_path)
    return secret_path unless account_name

    accounts = @options['accounts']
    unless accounts && accounts.key?(account_name)
      raise ArgumentError, "account '#{account_name}' not found in options.accounts configuration"
    end

    account_config = accounts[account_name]
    account_id = account_config['account_id']
    region = account_config['region'] || @options['region']

    unless account_id
      raise ArgumentError, "account_id not set for account '#{account_name}' in options.accounts"
    end

    "arn:aws:secretsmanager:#{region}:#{account_id}:secret:#{secret_path}"
  end

  def cached_or_fetch_secret(secret_id)
    unless @context.cache_has_key(secret_id)
      response = fetch_secret_from_agent(secret_id)

      unless response.is_a?(Net::HTTPSuccess)
        @context.explain { "Secret not found or agent error: #{secret_id} (HTTP #{response.code})" }
        return @context.not_found
      end

      @context.explain { "Found secret: #{secret_id}" }

      secret_string = parse_agent_response(response.body)
      interpolated_string = @context.interpolate(secret_string)

      secret_object = JSON.parse(interpolated_string)

      @context.explain { "Secret parsed as JSON:\n#{secret_object.inspect}" }
      @context.cache(secret_id, secret_object)
    end

    @context.cached_value(secret_id)
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

  def fetch_secret_from_agent(secret_id)
    host = @options['agent_host'] || AGENT_DEFAULT_HOST
    port = (@options['agent_port'] || AGENT_DEFAULT_PORT).to_i
    token = ssrf_token

    encoded_id = URI.encode_www_form_component(secret_id)
    uri = URI("http://#{host}:#{port}/v1/secrets/#{encoded_id}")

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
