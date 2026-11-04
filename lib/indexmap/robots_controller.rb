# frozen_string_literal: true

require "indexmap"
require "action_controller"

class Indexmap::RobotsController < ActionController::Base
  def show
    body = Indexmap.configuration.robots.body
    expires_in 1.hour, public: true
    fresh_when etag: body, public: true, template: false
    render plain: body, content_type: "text/plain" unless performed?
  end
end
