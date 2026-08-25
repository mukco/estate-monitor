# frozen_string_literal: true

require "rails"

module Estate
  module Monitor
    class Engine < ::Rails::Engine
      isolate_namespace Estate::Monitor
    end
  end
end
