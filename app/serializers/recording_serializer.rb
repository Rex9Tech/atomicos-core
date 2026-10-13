# app/serializers/recording_serializer.rb

class RecordingSerializer < ApplicationSerializer
  attributes :id, :title, :status, :duration_secs, :started_at, :ended_at,
             :atom_id, :metadata, :created_at, :updated_at
end
