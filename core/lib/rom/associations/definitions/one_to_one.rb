require 'rom/associations/definitions/abstract'

module ROM
  module Associations
    module Definitions
      class OneToOne < Abstract
        result :one
      end
    end
  end
end
