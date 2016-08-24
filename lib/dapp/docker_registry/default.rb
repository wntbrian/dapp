module Dapp
  # DockerRegistry
  module DockerRegistry
    # Default
    class Default < Base
      DEFAULT_HOSTNAME_URL = 'https://registry.hub.docker.com'.freeze

      def initialize(repo, repo_suffix)
        super(repo, DEFAULT_HOSTNAME_URL, repo_suffix)
      end

      def repo_suffix=(val)
        val = "library/#{val}" if val.split('/').one?
        super(val)
      end

      def image_id_by_tag(_tag)
        raise
      end
    end
  end
end # Dapp
