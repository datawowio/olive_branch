require "multi_json"

module OliveBranch
  class Checks
    def self.content_type_check(content_type)
      content_type =~ /application\/json/ || /application\/x-www-form-urlencoded/
    end

    def self.default_exclude(env)
      false
    end
  end

  class Transformations
    class << self
      def transform(value, transform_method)
        case value
        when Array then value.map { |item| transform(item, transform_method) }
        when Hash then value.deep_transform_keys! { |key| transform(key, transform_method) }
        when String then transform_method.call(value)
        else value
        end
      end

      def camelize(string)
        string.underscore.camelize(:lower)
      end

      def dasherize(string)
        string.dasherize
      end

      def underscore_params(env)
        req = ActionDispatch::Request.new(env)
        req.request_parameters
        req.query_parameters

        env["action_dispatch.request.request_parameters"].deep_transform_keys!(&:underscore)
        env["action_dispatch.request.query_parameters"].deep_transform_keys!(&:underscore)
      end
    end
  end

  class Middleware
    def initialize(app, args = {})
      @app = app
      @camelize = args[:camelize] || Transformations.method(:camelize)
      @dasherize = args[:dasherize] || Transformations.method(:dasherize)
      @content_type_check = args[:content_type_check] || Checks.method(:content_type_check)
      @exclude_response = args[:exclude_response] || Checks.method(:default_exclude)
      @exclude_params = args[:exclude_params] || Checks.method(:default_exclude)
      @default_inflection = args[:inflection]
    end

    def call(env)
      Transformations.underscore_params(env) unless exclude_params?(env)

      @app.call(env).tap do |_status, headers, response|
        next if exclude_response?(env, headers)

        response.each do |body|
          begin
            new_response = MultiJson.load(body)
          rescue MultiJson::ParseError
            next
          end

          Transformations.transform(new_response, inflection_method(env))

          body.replace(MultiJson.dump(new_response))
        end
      end
    end

    private

    def exclude_params?(env)
      exclude?(env, env["CONTENT_TYPE"], @exclude_params)
    end

    def exclude_response?(env, headers)
      exclude?(env, headers["Content-Type"], @exclude_response)
    end

    def exclude?(env, content_type, block)
      !inflection_type(env) || !valid_content_type?(content_type) || block.call(env)
    end

    def valid_content_type?(content_type)
      @content_type_check.call(content_type)
    end

    def inflection_type(env)
      env["HTTP_X_KEY_INFLECTION"] || @default_inflection
    end

    def inflection_method(env)
      inflection = inflection_type(env)

      if inflection == "camel"
        @camelize
      elsif inflection == "dash"
        @dasherize
      else
        # probably misconfigured, do nothing
        -> (string) { string }
      end
    end
  end
end
