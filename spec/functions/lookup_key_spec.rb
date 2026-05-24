require 'spec_helper'

require 'net/http'

describe :hiera_aws_secretsmanager do
  context 'without arguments' do
    it { should_not be_nil }
    it { should run.with_params().and_raise_error(ArgumentError) }
  end

  let (:key) { 'test::key' }
  let (:translated_key) { key.tr(':', '=') }
  let (:main_role_arn) { 'arn:aws:iam::123456789012:role/PuppetSecretsRole' }
  let (:staging_role_arn) { 'arn:aws:iam::987654321098:role/PuppetSecretsRole' }
  let (:options) {
    {
      'uri' => 'test/secret/path',
      'agent_port' => 2773,
      'ssrf_env_var' => 'AWS_TOKEN',
      'default_account' => 'main',
      'accounts' => {
        'main' => {
          'role_arn' => main_role_arn,
        },
        'staging' => {
          'role_arn' => staging_role_arn,
        },
      },
    }
  }

  let (:context) {
    double(Puppet::Pops::Lookup::Context).tap do |ctx|
      allow(ctx).to receive(:explain) do
        if block_given?
          puts yield
        end
      end

      allow(ctx).to receive(:not_found).and_return(:not_found)

      allow(ctx).to receive(:interpolate).with(anything) do |string|
        if string['%{'] then
          STDERR.puts <<~END

            WARNING: In order to test strings with Puppet
            interpolations, you have to define an allow(context).to
            receive(:interpolation) block in your local context.

          END
          "unexpected interpolation tag found in '#{string}'"
        else
          string
        end
      end
    end
  }

  let (:secret_string) { 'test-secret' }
  let (:agent_response_body) { { 'SecretString' => secret_string.to_json }.to_json }

  let (:http_response) {
    instance_double(Net::HTTPOK).tap do |resp|
      allow(resp).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(resp).to receive(:body).and_return(agent_response_body)
      allow(resp).to receive(:code).and_return('200')
    end
  }

  before do
    ENV['AWS_TOKEN'] = 'test-ssrf-token'
    allow(Net::HTTP).to receive(:start).and_yield(
      instance_double(Net::HTTP).tap do |http|
        allow(http).to receive(:request).and_return(http_response)
      end
    )
  end

  after do
    ENV.delete('AWS_TOKEN')
  end

  context 'configuration validation' do
    context 'when no uri is given' do
      before { options.delete('uri') }

      it 'raises an ArgumentError' do
        expect(subject)
          .to run.with_params(key, options, context)
          .and_raise_error(ArgumentError, /uri/)
      end
    end
  end

  context 'account parsing' do
    context 'with an account-prefixed key' do
      let (:key) { 'staging:-test::key' }

      it 'sends the staging role_arn as a query parameter' do
        expect(Net::HTTP).to receive(:start).and_yield(
          instance_double(Net::HTTP).tap do |http|
            expect(http).to receive(:request) do |req|
              query = URI.decode_www_form(URI("http://x#{req.path}").query).to_h
              expect(query['roleArn']).to eq(staging_role_arn)
              http_response
            end
          end
        )
        expect(subject).to run.with_params(key, options, context).and_return(secret_string)
      end
    end

    context 'with a key without prefix and default_account set' do
      it 'sends the default account role_arn as a query parameter' do
        expect(Net::HTTP).to receive(:start).and_yield(
          instance_double(Net::HTTP).tap do |http|
            expect(http).to receive(:request) do |req|
              query = URI.decode_www_form(URI("http://x#{req.path}").query).to_h
              expect(query['roleArn']).to eq(main_role_arn)
              http_response
            end
          end
        )
        expect(subject).to run.with_params(key, options, context).and_return(secret_string)
      end
    end

    context 'with a key without prefix and no default_account' do
      before { options.delete('default_account') }

      it 'does not include roleArn in the query' do
        expect(Net::HTTP).to receive(:start).and_yield(
          instance_double(Net::HTTP).tap do |http|
            expect(http).to receive(:request) do |req|
              query = URI.decode_www_form(URI("http://x#{req.path}").query).to_h
              expect(query).not_to have_key('roleArn')
              http_response
            end
          end
        )
        expect(subject).to run.with_params(key, options, context).and_return(secret_string)
      end
    end

    context 'with an unknown account prefix' do
      let (:key) { 'unknown:-test::key' }

      it 'raises an ArgumentError' do
        expect(subject)
          .to run.with_params(key, options, context)
          .and_raise_error(ArgumentError, /account 'unknown' not found/)
      end
    end

    context 'with an account missing role_arn' do
      before { options['accounts']['main'].delete('role_arn') }

      it 'raises an ArgumentError' do
        expect(subject)
          .to run.with_params(key, options, context)
          .and_raise_error(ArgumentError, /role_arn not set/)
      end
    end
  end

  context 'key translation' do
    it 'converts : to = in the secret key portion' do
      expect(Net::HTTP).to receive(:start).and_yield(
        instance_double(Net::HTTP).tap do |http|
          expect(http).to receive(:request) do |req|
            query = URI.decode_www_form(URI("http://x#{req.path}").query).to_h
            expect(query['secretId']).to include(translated_key)
            http_response
          end
        end
      )
      expect(subject).to run.with_params(key, options, context)
    end
  end

  context 'agent communication' do
    it 'sends the SSRF token header' do
      expect(Net::HTTP).to receive(:start).and_yield(
        instance_double(Net::HTTP).tap do |http|
          expect(http).to receive(:request) do |req|
            expect(req['X-Aws-Parameters-Secrets-Token']).to eq('test-ssrf-token')
            http_response
          end
        end
      )
      expect(subject).to run.with_params(key, options, context)
    end

    context 'when the agent returns a non-success response' do
      let (:http_response) {
        instance_double(Net::HTTPNotFound).tap do |resp|
          allow(resp).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
          allow(resp).to receive(:code).and_return('404')
        end
      }

      it 'returns not_found' do
        expect(subject).to run.with_params(key, options, context).and_return(:not_found)
      end
    end

    context 'when ssrf_env_var is not set' do
      before { options.delete('ssrf_env_var') }

      it 'sends the request without a token header' do
        expect(Net::HTTP).to receive(:start).and_yield(
          instance_double(Net::HTTP).tap do |http|
            expect(http).to receive(:request) do |req|
              expect(req['X-Aws-Parameters-Secrets-Token']).to be_nil
              http_response
            end
          end
        )
        expect(subject).to run.with_params(key, options, context)
      end
    end

    context 'when ssrf env var is set but empty' do
      before { ENV['AWS_TOKEN'] = '' }

      it 'raises an ArgumentError' do
        expect(subject)
          .to run.with_params(key, options, context)
          .and_raise_error(ArgumentError, /SSRF token environment variable/)
      end
    end
  end

  context 'response parsing' do
    context 'when the agent returns a GetSecretValue JSON response' do
      let (:agent_response_body) { { 'SecretString' => secret_string.to_json }.to_json }

      it 'extracts and parses SecretString' do
        expect(subject).to run.with_params(key, options, context).and_return(secret_string)
      end
    end

    context 'when the agent returns a plain body' do
      let (:agent_response_body) { secret_string.to_json }

      it 'parses the body directly as JSON' do
        expect(subject).to run.with_params(key, options, context).and_return(secret_string)
      end
    end

    context 'when secret is a JSON object' do
      let (:secret_value) { { 'test_hash_key' => 'test_hash_value' } }
      let (:agent_response_body) { { 'SecretString' => secret_value.to_json }.to_json }

      it 'returns the parsed JSON object as a Ruby Hash' do
        expect(subject).to run
          .with_params(key, options, context)
          .and_return(secret_value)
      end

    end

    context 'when secret is a JSON array' do
      let (:secret_value) { ['test-a1'] }
      let (:agent_response_body) { { 'SecretString' => secret_value.to_json }.to_json }

      it 'returns the parsed JSON object as a Ruby Array' do
        expect(subject).to run
          .with_params(key, options, context)
          .and_return(secret_value)
      end

    end

    context 'when secret contains Puppet interpolation tokens' do
      let (:secret_value) { 'test-%{}' }
      let (:interpolated_value) { 'test-secret' }
      let (:agent_response_body) { { 'SecretString' => secret_value.to_json }.to_json }

      it 'does Puppet interpolation before JSON parsing' do
        expect(context).to receive(:interpolate)
          .with(secret_value.to_json)
          .and_return(interpolated_value.to_json)

        expect(subject).to run.with_params(key, options, context).and_return(interpolated_value)
      end
    end
  end


end
