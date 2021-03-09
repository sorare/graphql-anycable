# frozen_string_literal: true

require "anycable"
require "graphql/subscriptions"

# rubocop: disable Metrics/AbcSize, Metrics/LineLength, Metrics/MethodLength

# A subscriptions implementation that sends data as AnyCable broadcastings.
#
# Since AnyCable is aimed to be compatible with ActionCable, this adapter
# may be used as (practically) drop-in replacement to ActionCable adapter
# shipped with graphql-ruby.
#
# @example Adding AnyCableSubscriptions to your schema
#   MySchema = GraphQL::Schema.define do
#     use GraphQL::Subscriptions::AnyCableSubscriptions
#   end
#
# @example Implementing a channel for GraphQL Subscriptions
#   class GraphqlChannel < ApplicationCable::Channel
#     def execute(data)
#       query = data["query"]
#       variables = ensure_hash(data["variables"])
#       operation_name = data["operationName"]
#       context = {
#         current_user: current_user,
#         # Make sure the channel is in the context
#         channel: self,
#       }
#
#       result = MySchema.execute({
#         query: query,
#         context: context,
#         variables: variables,
#         operation_name: operation_name
#       })
#
#       payload = {
#         result: result.subscription? ? {data: nil} : result.to_h,
#         more: result.subscription?,
#       }
#
#       transmit(payload)
#     end
#
#     def unsubscribed
#       channel_id = params.fetch("channelId")
#       MySchema.subscriptions.delete_channel_subscriptions(channel_id)
#     end
#   end
#
module GraphQL
  class Subscriptions
    class AnyCableSubscriptions < GraphQL::Subscriptions
      extend Forwardable

      def_delegators :"GraphQL::AnyCable", :redis, :config

      SUBSCRIPTION_PREFIX = "graphql-subscription:"
      SUBSCRIPTION_EVENTS_PREFIX = "graphql-subscription-events:"
      SUBSCRIPTION_EVENTS_FINGERPRINT_PREFIX = "graphql-subscription-events-fingerprint:"
      EVENT_FINGERPRINT_PREFIX = "graphql-event-fingerprint:"
      CHANNEL_PREFIX = "graphql-channel:"

      # @param serializer [<#dump(obj), #load(string)] Used for serializing messages before handing them to `.broadcast(msg)`
      def initialize(serializer: Serialize, **rest)
        @serializer = serializer
        super
      end

      # An event was triggered.
      # Re-evaluate all subscribed queries and push the data over ActionCable.
      def execute_all(event, object)
        redis.smembers(SUBSCRIPTION_EVENTS_FINGERPRINT_PREFIX + event.topic).each do |fingerprint|
          subscriptions = redis.smembers(EVENT_FINGERPRINT_PREFIX + fingerprint)
          result = execute_update(subscriptions.first, event, object)
          # Having calculated the result _once_, send the same payload to all subscribers
          payload = { result: result.to_h, more: true }.to_json.freeze
          subscriptions.each do |subscription_id|
            deliver(subscription_id, payload)
          end
        end
      end

      # This subscription was re-evaluated.
      # Send it to the specific stream where this client was waiting.
      def deliver(subscription_id, payload)
        anycable.broadcast(SUBSCRIPTION_PREFIX + subscription_id, payload)
      end

      # Save query to "storage" (in redis)
      def write_subscription(query, events)
        context = query.context.to_h
        subscription_id = context[:subscription_id] ||= build_id
        channel = context.delete(:channel)
        stream = context[:action_cable_stream] ||= SUBSCRIPTION_PREFIX + subscription_id
        channel.stream_from(stream)

        data = {
          query_string: query.query_string,
          variables: query.provided_variables.to_json,
          context: @serializer.dump(context.to_h),
          operation_name: query.operation_name
        }

        redis.multi do
          redis.sadd(CHANNEL_PREFIX + channel.params["channelId"], subscription_id)
          redis.mapped_hmset(SUBSCRIPTION_PREFIX + subscription_id, data)
          redis.sadd(SUBSCRIPTION_EVENTS_PREFIX + subscription_id, events.map(&:topic))
          events.each do |event|
            redis.sadd(SUBSCRIPTION_EVENTS_FINGERPRINT_PREFIX + event.topic, event.fingerprint)
            redis.sadd(EVENT_FINGERPRINT_PREFIX + event.fingerprint, subscription_id)
          end
          next unless config.subscription_expiration_seconds
          redis.expire(CHANNEL_PREFIX + channel.params["channelId"], config.subscription_expiration_seconds)
          redis.expire(SUBSCRIPTION_PREFIX + subscription_id, config.subscription_expiration_seconds)
        end
      end

      # Return the query from "storage" (in redis)
      def read_subscription(subscription_id)
        return nil unless subscription_id

        subscription = redis.mapped_hmget(
          "#{SUBSCRIPTION_PREFIX}#{subscription_id}",
          :query_string, :variables, :context, :operation_name
        )

        if subscription[:context]
          {
            **subscription,
            variables: JSON.parse(subscription[:variables]),
            context: @serializer.load(subscription[:context])
          }
        else
          # This can happen when a subscription is triggered from an unsubscribed channel,
          # see https://github.com/rmosolgo/graphql-ruby/issues/2478.
          # (This `nil` is handled by `#execute_update`)
          nil
        end
      end

      # The channel was closed, forget about it.
      def delete_subscription(subscription_id)
        return unless subscription_id

        # Remove subscription ids from all events
        topics = redis.smembers(SUBSCRIPTION_EVENTS_PREFIX + subscription_id)
        topics.each do |event_topic|
          redis.smembers(SUBSCRIPTION_EVENTS_FINGERPRINT_PREFIX + event_topic).each do |fingerprint|
            redis.srem(EVENT_FINGERPRINT_PREFIX + fingerprint, subscription_id)

            redis.srem(SUBSCRIPTION_EVENTS_FINGERPRINT_PREFIX + event_topic, fingerprint) if redis.scard(EVENT_FINGERPRINT_PREFIX + fingerprint).zero?
          end
        end
        # Delete subscription itself
        redis.del(SUBSCRIPTION_EVENTS_PREFIX + subscription_id)
        redis.del(SUBSCRIPTION_PREFIX + subscription_id)
      end

      def delete_channel_subscriptions(channel_id)
        redis.smembers(CHANNEL_PREFIX + channel_id).each do |subscription_id|
          delete_subscription(subscription_id)
        end
        redis.del(CHANNEL_PREFIX + channel_id)
      end

      private

      def anycable
        @anycable ||= ::AnyCable.broadcast_adapter
      end
    end
  end
end
# rubocop: enable Metrics/AbcSize, Metrics/LineLength, Metrics/MethodLength
