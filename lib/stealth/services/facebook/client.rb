# coding: utf-8
# frozen_string_literal: true

require 'http'

require 'stealth/services/facebook/message_handler'
require 'stealth/services/facebook/reply_handler'
require 'stealth/services/facebook/setup'

module Stealth
  module Services
    module Facebook
      class Client < Stealth::Services::BaseClient

        FB_URL = ENV['FACEBOOK_API_URL'] || "graph.facebook.com"
        FB_HTTP_PROTOCOL = ENV['FACEBOOK_HTTP_PROTOCOL'] || "https"

        FB_ENDPOINT = if ENV['FACEBOOK_API_VERSION'].present?
          "#{FB_HTTP_PROTOCOL}://#{FB_URL}/v#{ENV['FACEBOOK_API_VERSION']}/me"
        else
          "#{FB_HTTP_PROTOCOL}://#{FB_URL}/v3.2/me"
        end

        attr_reader :api_endpoint, :reply

        def initialize(reply:, endpoint: 'messages')
          @reply = reply
          access_token = "access_token=#{Stealth.config.facebook.page_access_token}"
          @api_endpoint = [[FB_ENDPOINT, endpoint].join('/'), access_token].join('?')
        end

        def transmit
          res = self
                  .class
                  .http_client
                  .post(api_endpoint, body: MultiJson.dump(reply))

          if res.status.client_error? # HTTP 4xx error
            # Messenger error sub-codes (https://developers.facebook.com/docs/messenger-platform/reference/send-api/error-codes)
            case res.body
            when /1545041/
              raise Stealth::Errors::UserOptOut
            when /2018108/
              raise Stealth::Errors::UserOptOut
            when /2018028/
              raise Stealth::Errors::InvalidSessionID.new('Cannot message users who are not admins, developers or testers of the app until pages_messaging permission is reviewed and the app is live.')
            end
          end

          Stealth::Logger.l(
            topic: "facebook",
            message: "Transmitted. Response: #{res.status.code}: #{res.body}"
          )
        end

        def self.http_client
          headers = {
            'Content-Type' => 'application/json'
          }
          HTTP.timeout(connect: 15, read: 60).headers(headers)
        end

        def self.fetch_profile(recipient_id:, fields: nil)
          if fields.blank?
            fields = [:id, :name, :first_name, :last_name, :profile_pic]
          end

          query_hash = {
            fields: fields.join(','),
            access_token: Stealth.config.facebook.page_access_token
          }

          if FB_HTTP_PROTOCOL == 'https'
            uri = URI::HTTPS.build(
              host: FB_URL,
              path: "/#{recipient_id}",
              query: query_hash.to_query
            )
          elsif FB_HTTP_PROTOCOL == 'http'
            uri = URI::HTTP.build(
              host: FB_URL,
              path: "/#{recipient_id}",
              query: query_hash.to_query
            )
          end

          res = http_client.get(uri.to_s)
          Stealth::Logger.l(topic:
            'facebook',
            message: "Requested user profile for #{recipient_id}. Response: #{res.status.code}: #{res.body}"
          )

          if res.status.success?
            MultiJson.load(res.body.to_s)
          else
            raise(
              Stealth::Errors::ServiceError,
              "Facebook error #{res.status}: #{res.body}"
            )
          end
        end

        def self.track(recipient_id:, metric:, value:, options: {})
          metric_values = [{
            '_eventName' => metric,
            '_valueToSum' => value
          }]

          metric_values.first.merge!(options)

          params = {
            event: 'CUSTOM_APP_EVENTS',
            custom_events: MultiJson.dump(metric_values),
            advertiser_tracking_enabled: 1,
            application_tracking_enabled: 1,
            extinfo: MultiJson.dump(['mb1']),
            page_scoped_user_id: recipient_id,
            page_id: Stealth.config.facebook.page_id
          }

          if FB_HTTP_PROTOCOL == 'https'
            uri = URI::HTTPS.build(
              host: FB_URL,
              path: "/#{Stealth.config.facebook.app_id}/activities"
            )
          elsif FB_HTTP_PROTOCOL == 'http'
            uri = URI::HTTP.build(
              host: FB_URL,
              path: "/#{Stealth.config.facebook.app_id}/activities"
            )
          end

          res = http_client.post(uri.to_s, body: MultiJson.dump(params))
          Stealth::Logger.l(
            topic: "facebook",
            message: "Sent custom event for metric: #{metric} and value: #{value}. Response: #{res.status}: #{res.body}"
          )

          if res.status.success?
            MultiJson.load(res.body.to_s)
          else
            raise(
              Stealth::Errors::ServiceError,
              "Facebook error #{res.status}: #{res.body}"
            )
          end
        end

      end
    end
  end
end
