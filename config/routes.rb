# frozen_string_literal: true

Estate::Monitor::Engine.routes.draw do
  root to: "metrics#show"
end
