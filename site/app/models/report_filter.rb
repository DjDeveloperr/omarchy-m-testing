# The filters a reader picks on the matrix and the reports list, from the
# query string, so every filtered view is a link and the exports take the
# same parameters. Every filter narrows (they combine with AND); a value the
# site doesn't know matches nothing, and a malformed one is dropped.
#
# Which runs:
#   build     a build (Build#matches?: its runtime id, label or words)
#   set       the candidate set the build is on (Build#set)
#   release   the Omarchy release (Report#omarchy_version, "4.0.0")
#   kernel    the running kernel release (Report#kernel, uname -r)
#   stack     the stack (CompatibilityMatrix::STACKS)
#   model     a Mac model, by board ("j416c")
#   gen       a chip generation ("m1": M1 and its Pro, Max and Ultra)
#   chip      a chip ("M1 Pro")
#   soc       an SoC ("t6000")
#   runs      "tester" (tester runs only) or "community"
#   tool      the omarchy-m-test version that ran it ("0.1.8")
#   from, to  uploaded on or after, on or before a day (YYYY-MM-DD, UTC)
#
# Which results:
#   confirmed "1": leave out results nobody confirmed, answers given by a
#             bare Enter, and on the matrix the cells community machines
#             don't agree on yet
#   layer     the matrix columns and check rows of one catalogue layer
#   state     the matrix rows and columns with a cell in this state, the
#             check rows with this result (works, partial, fails,
#             regression, gap, untested)
class ReportFilter
  RUN_KEYS = %w[build set release kernel stack model gen chip soc runs tool from to].freeze
  RESULT_KEYS = %w[confirmed layer state].freeze
  KEYS = (RUN_KEYS + RESULT_KEYS).freeze
  # What a list of runs takes: which runs, and whether their counts leave out answers by default.
  LIST_KEYS = (RUN_KEYS + %w[confirmed]).freeze
  # The feature catalogue narrows its result boxes to a model and/or build.
  FEATURE_KEYS = %w[model build].freeze

  RUNS = %w[tester community].freeze
  # A filter state => the matrix states (ResultState) it picks.
  STATES = {
    "works" => %w[works], "partial" => %w[partial], "fails" => %w[fails], "regression" => %w[regression],
    "gap" => %w[missing], "untested" => %w[not-tested]
  }.freeze
  STATE_WORDS = { "works" => "works", "partial" => "partial", "fails" => "doesn't work", "regression" => "regression",
                  "gap" => "expected missing (gap)", "untested" => "not tested" }.freeze
  LABELS = {
    "build" => "build", "set" => "candidate set", "release" => "release", "kernel" => "kernel", "stack" => "stack", "model" => "model", "gen" => "generation",
    "chip" => "chip", "soc" => "SoC", "runs" => "runs", "tool" => "tester version", "from" => "from", "to" => "to",
    "confirmed" => "results", "layer" => "layer", "state" => "state"
  }.freeze
  DATE = /\A\d{4}-\d{2}-\d{2}\z/
  # Build words run long (an image naming its set carries its runtime, kernel, boot package, build time and digest).
  MAX_LENGTH = 2048

  attr_reader :values

  # params: the request's (or any Hash-like). keys: the filters this view takes.
  def initialize(params = {}, keys: KEYS)
    params = params.to_unsafe_h if params.respond_to?(:to_unsafe_h)
    @values = keys.each_with_object({}) do |key, values|
      value = clean(key, params[key] || params[key.to_sym])
      values[key] = value if value
    end
  end

  def [](key) = values[key]
  def any? = values.any?
  def empty? = values.empty?
  def confirmed? = values["confirmed"] == "1"
  def layer = values["layer"]
  def state = values["state"]
  def matrix_states = STATES[state]

  # The runs among `reports` that every run filter passes, in their order.
  def runs(reports)
    return reports.to_a if (values.keys & RUN_KEYS).empty?

    reports.select { |report| run?(report) }
  end

  def run?(report)
    values.all? do |key, value|
      case key
      when "build" then report.build&.matches?(value)
      when "set" then report.build&.set == value
      when "release" then report.omarchy_version == value
      when "kernel" then report.kernel == value
      when "stack" then report.stack == value
      when "model" then report.board == value
      when "gen" then Catalogue.chip_for_soc(report.soc).to_s.split("-").first == value
      when "chip" then report.chip == value
      when "soc" then report.soc == value
      when "runs" then report.tester? == (value == "tester")
      when "tool" then report.tool_version == value
      when "from" then report.created_at.utc.to_date >= Date.iso8601(value)
      when "to" then report.created_at.utc.to_date <= Date.iso8601(value)
      else true
      end
    end
  end

  # The checks of a report this filter keeps (the checks export): all but
  # answers by default when confirmed, of one layer, with one result.
  def checks(report)
    report.checks.select do |check|
      next false if confirmed? && Report.answered_by_default?(check)
      next false if layer && check.dig("classification", "layer") != layer
      next false if state && !STATES.fetch(state).include?(check_state(report, check))

      true
    end
  end

  # [[key, value, words], ...] for the chips.
  def chips
    values.map { |key, value| [ key, value, "#{LABELS.fetch(key)}: #{words(key, value)}" ] }
  end

  # The query parameters for this filter, less `except`, with `extra` (e.g. group: "release").
  def to_params(except: nil, **extra) = values.except(*Array(except).map(&:to_s)).merge(extra.compact.transform_keys(&:to_s))

  # Chip generations the catalogue knows ("m1", "m2", ...), in its order.
  def self.generations = Catalogue.chips.keys.map { |key| key.split("-").first }.uniq

  private

  def check_state(report, check)
    state = ResultState.for_outcome(check.dig("classification", "outcome"))
    state == "fails" && report.regression?(check.dig("classification", "feature")) ? "regression" : state
  end

  def words(key, value)
    case key
    when "stack" then Report::STACK_WORDS.fetch(value, value)
    when "gen" then value.upcase
    when "runs" then value == "tester" ? "tester runs only" : "community runs only"
    when "confirmed" then "confirmed only"
    when "layer" then Catalogue::LAYER_WORDS.fetch(value, value)
    when "state" then STATE_WORDS.fetch(value, value)
    else value
    end
  end

  def clean(key, value)
    return unless value.is_a?(String)

    value = value.strip
    return if value.empty? || value.length > MAX_LENGTH

    case key
    when "stack" then value.presence_in(CompatibilityMatrix::STACKS)
    when "runs" then value.presence_in(RUNS)
    when "confirmed" then value.presence_in(%w[1])
    when "layer" then value.presence_in(Catalogue::LAYERS)
    when "state" then value.presence_in(STATES.keys)
    when "gen" then value.downcase.presence_in(self.class.generations)
    when "from", "to" then value if value.match?(DATE) && (Date.iso8601(value) rescue false)
    else value
    end
  end
end
