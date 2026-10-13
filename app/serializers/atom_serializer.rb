# app/serializers/atom_serializer.rb

class AtomSerializer < ApplicationSerializer
  attributes :id, :title, :source, :status, :duration_secs, :participants_count,
             :summary_blocks, :transcript_segments, :note, :room_id,
             :recording_status, :metadata, :category_id, :meeting_at,
             :created_at, :updated_at
end
