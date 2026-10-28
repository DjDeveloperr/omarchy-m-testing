class PagesController < ApplicationController
  def home
    reports = Report.visible.to_a
    @matrix = CompatibilityMatrix.visible(by_model: true, reports:)
    @history = CompatibilityMatrix.visible(reports:).rows.group_by { |row| [ row.configuration.board, row.configuration.stack ] }
  end

  def data
  end
end
