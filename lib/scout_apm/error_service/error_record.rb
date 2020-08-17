module ScoutApm
  module ErrorService
    # Converts the raw error data captured into the captured data, and holds it
    # until it's ready to be reported.
    class ErrorRecord
      attr_reader :exception_class
      attr_reader :message
      attr_reader :request_uri
      attr_reader :request_params
      attr_reader :request_session
      attr_reader :environment
      attr_reader :trace
      attr_reader :request_components

      def initialize(context, exception, env)
        @context = context

        @exception_class = exception.class.name
        @message = exception.message
        @request_uri = rack_request_url(env)
        @request_params = clean_params(env["action_dispatch.request.parameters"])
        @request_session = clean_params(session_data(env))
        @environment = clean_params(strip_env(env))
        @trace = clean_backtrace(exception.backtrace)
        @request_components = components(env)
      end

      # TODO: This is rails specific
      def components(env)
        components = {}
        unless env["action_dispatch.request.parameters"].nil?
          components[:controller] = env["action_dispatch.request.parameters"][:controller] || nil
          components[:action] = env["action_dispatch.request.parameters"][:action] || nil
          components[:module] = env["action_dispatch.request.parameters"][:module] || nil
        end

        # For background workers like sidekiq
        # TODO: extract data creation for background jobs
        components[:controller] ||= env[:custom_controller]

        components
      end

      # TODO: Can I use the same thing we use in traces?
      def rack_request_url(env)
        protocol = rack_scheme(env)
        protocol = protocol.nil? ? "" : "#{protocol}://"

        host = env["SERVER_NAME"] || ""
        path = env["REQUEST_URI"] || ""
        port = env["SERVER_PORT"] || "80"
        port = ["80", "443"].include?(port.to_s) ? "" : ":#{port}"

        protocol.to_s + host.to_s + port.to_s + path.to_s
      end

      def rack_scheme(env)
        if env["HTTPS"] == "on"
          "https"
        elsif env["HTTP_X_FORWARDED_PROTO"]
          env["HTTP_X_FORWARDED_PROTO"].split(",")[0]
        else
          env["rack.url_scheme"]
        end
      end

      # TODO: This name is too vague
      def clean_params(params)
        return if params.nil?
        params = normalize_data(params)
        params = filter_params(params)
      end

      # TODO: When was backtrace_cleaner introduced?
      def clean_backtrace(backtrace)
        if defined?(Rails) && Rails.respond_to?(:backtrace_cleaner)
          Rails.backtrace_cleaner.send(:filter, backtrace)
        else
          backtrace
        end
      end

      # Deletes params from env / set in config file
      # TODO: Make sure this is fast enough - I don't think we want to duplicate the entirity of env? (which reject does)
      KEYS_TO_REMOVE = ["rack.request.form_hash", "rack.request.form_vars", "async.callback"]
      def strip_env(env)
        env.reject { |k, v| KEYS_TO_REMOVE.include?(k) }
      end

      def session_data(env)
        session = env["action_dispatch.request.session"]
        return if session.nil?

        if session.respond_to?(:to_hash)
          session.to_hash
        else
          session.data
        end
      end

      # TODO: Rename and make this clearer. I think it maps over the whole tree of a hash, and to_s each leaf node?
      def normalize_data(hash)
        new_hash = {}

        hash.each do |key, value|
          if value.respond_to?(:to_hash)
            begin
              new_hash[key] = normalize_data(value.to_hash)
            rescue
              new_hash[key] = value.to_s
            end
          else
            new_hash[key] = value.to_s
          end
        end

        new_hash
      end

      ###################
      # Filtering Params
      ###################

      # Replaces parameter values with a string / set in config file
      def filter_params(params)
        return params unless filtered_params_config

        params.each do |k, v|
          if filter_key?(k)
            params[k] = "[FILTERED]"
          elsif v.respond_to?(:to_hash)
            filter_params(params[k])
          end
        end

        params
      end

      # Check, if a key should be filtered
      def filter_key?(key)
        filtered_params_config.any? do |filter|
          key.to_s == filter.to_s # key.to_s.include?(filter.to_s)
        end
      end

      # Accessor for the filtered params config value. Will be removed as we refactor and clean up this code.
      # TODO: Flip this over to use a new class like filtered exceptions?
      def filtered_params_config
        ScoutApm::Agent.instance.context.config.value("errors_filtered_params")
      end
    end
  end
end
