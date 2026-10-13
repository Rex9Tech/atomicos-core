# app/serializers/category_serializer.rb

class CategorySerializer < ApplicationSerializer
  attributes :id, :name, :slug, :description, :position, :created_at, :updated_at

  # Kept atoms inside this molecule — shown on the home molecule cards.
  attribute :atoms_count do |category|
    category.atoms.count
  end
end
