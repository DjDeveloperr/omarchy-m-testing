class FeaturesController < ApplicationController
  def index
    load_results
    @features = Catalogue.features.group_by { |feature| feature.fetch("layer") }
  end

  def show
    @feature = Catalogue.feature(params[:id]) or raise ActiveRecord::RecordNotFound
    load_results
    # One summary row per model and stack, each with its builds' rows as history.
    @rows = CompatibilityMatrix.visible(filter: @filter, reports: @reports, by_model: true).rows_for_feature(@feature.fetch("id"))
    @history = @matrix.rows_for_feature(@feature.fetch("id")).group_by { |row| [ row.configuration.board, row.configuration.stack ] }
  end

  private

  def load_results
    @reports = Report.visible.to_a
    @filter = ReportFilter.new(params, keys: ReportFilter::FEATURE_KEYS)
    @matrix = CompatibilityMatrix.visible(filter: @filter, reports: @reports)
    @options = FilterOptions.new(@reports, filter: @filter)
  end
end
