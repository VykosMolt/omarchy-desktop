function secondsFromConfig(value, fallback) {
  var n = Number(value)
  if (!isFinite(n) || n < 0) return fallback
  return Math.floor(n)
}

// The stages that are switched on, earliest first. A stage set to 0 is off, so
// it neither fires nor decides when the idle monitor first reports idle.
function enabledTimeouts(values) {
  var out = []
  for (var i = 0; i < values.length; i++) {
    var seconds = Number(values[i])
    if (isFinite(seconds) && seconds > 0) out.push(Math.floor(seconds))
  }
  return out.sort(function(a, b) { return a - b })
}

if (typeof module !== "undefined") {
  module.exports = {
    secondsFromConfig: secondsFromConfig,
    enabledTimeouts: enabledTimeouts
  }
}
