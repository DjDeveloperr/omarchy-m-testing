# What a feature does on a Mac, in the site's colour code:
#
#   works           green    every tested check works
#   partial         yellow   some checks work and others don't, or machines disagree
#   regression      red      doesn't work, and a verified earlier run on the same
#                            model and stack found it working (Regressions)
#   fails           orange   doesn't work although it should on this Mac, with no
#                            verified earlier pass to call it a regression
#   missing         blue     expected missing: not yet in Aurora, Asahi or Omarchy
#   unknown         magenta  unknown hardware
#   not-applicable  (none)   this Mac doesn't have the hardware
#   not-tested      grey     no check was run
module ResultState
  ORDER = %w[works partial regression fails missing unknown not-applicable not-tested].freeze

  WORDS = {
    "works" => "works",
    "partial" => "partial",
    "regression" => "regression",
    "fails" => "doesn't work",
    "missing" => "expected missing",
    "unknown" => "unknown hardware",
    "not-applicable" => "not on this Mac",
    "not-tested" => "not tested"
  }.freeze

  # What a colour means, for tooltips.
  MEANINGS = {
    "works" => "works",
    "partial" => "partly works: some checks pass and others don't, or machines disagree",
    "regression" => "regression: a tester's earlier run on this model found it working",
    "fails" => "doesn't work, although it should on this Mac",
    "missing" => "expected missing: not supported yet by Aurora, Asahi or Omarchy",
    "unknown" => "unknown hardware: nothing in the catalogue drives it",
    "not-applicable" => "this Mac doesn't have the hardware",
    "not-tested" => "not tested"
  }.freeze

  GLYPHS = {
    "works" => "✓", "partial" => "~", "regression" => "✗", "fails" => "!", "missing" => "·",
    "unknown" => "?", "not-applicable" => "–", "not-tested" => " "
  }.freeze

  OUTCOMES = {
    "works" => "works",
    "fails" => "fails",
    "not-in-aurora" => "missing",
    "not-in-asahi" => "missing",
    "not-in-omarchy" => "missing",
    "not-applicable" => "not-applicable",
    "unknown-hardware" => "unknown",
    "not-tested" => "not-tested"
  }.freeze

  def self.for_outcome(outcome) = OUTCOMES.fetch(outcome, "unknown")
  def self.words(state) = WORDS.fetch(state)
  def self.meaning(state) = MEANINGS.fetch(state)
  def self.glyph(state) = GLYPHS.fetch(state)

  # One report's state for a feature, from the outcomes of the checks that test it.
  def self.combine(outcomes)
    states = outcomes.map { |outcome| for_outcome(outcome) }.uniq - [ "not-tested" ]
    return "not-tested" if states.empty?
    return states.first if states.one?
    return "partial" if states.include?("works")

    %w[regression fails unknown missing not-applicable].find { |state| states.include?(state) }
  end
end
