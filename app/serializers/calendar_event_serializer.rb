# app/serializers/calendar_event_serializer.rb

class CalendarEventSerializer < ApplicationSerializer
  attributes :id, :title, :start_at, :end_at, :description, :status,
             :metadata, :created_at, :updated_at
end
