# Prediction API

The Evaluate tab's **Predictions** screen draws what a model predicted at a chosen moment, using only the data available then, beside what glucose actually did. The screen contains no glucose math. Any model that follows this contract can be registered and selected from the model picker.

Units: glucose in mg/dl, insulin in u, times in seconds since 1970-01-01 UTC, durations in seconds.

## Swift models

Implement `PredictionModel` (`Sources/PredictionModel.swift`) and register it:

```swift
var registry = PredictionModelRegistry()
registry.register(MyModel())          // same id replaces the existing model
```

`predict(context:horizon:step:)` returns one or more named `PredictionSeries` (for example oref's `IOB`, `COB`, `UAM`, `ZT`). It throws `PredictionError` on failure; the screen shows the message instead of a chart. The evaluator hides all data after the chosen moment and ignores any predicted point at or before it.

## Script models (oref0, oref1, experimental, ...)

`ScriptPredictionModel(id:name:transport:)` sends the JSON request below to a `PredictionTransport` and validates the reply. Swapping models means registering another model with another transport; nothing else changes.

| Transport | Platform | How it runs the model |
| --- | --- | --- |
| `JavaScriptPredictionTransport(source:)` | iOS, macOS | Evaluates the source in JavaScriptCore and calls the global `predict(requestJSON)`, which returns the response JSON as a string. A fresh context per call. |
| `CommandPredictionTransport(executable:arguments:timeout:)` | macOS, Linux (development) | Request on standard input, response on standard output. Non-zero exit or timeout is a failure; standard error becomes the message. The timeout kills the command itself; wrapper scripts should `exec` the real program so no child keeps running. |

Other transports (a remote service, for example) only implement `exchange(_ request: Data) throws -> Data`.

### Request (version 1)

```json
{
  "version": 1,
  "time": 1700000300,
  "horizon": 7200,
  "step": 300,
  "readings": [{ "t": 1700000000, "mgdl": 100 }],
  "foods": [{ "t": 1700000100, "carbs": 30, "protein": 10, "fat": 5 }],
  "doses": [{ "t": 1700000000, "units": 2 }]
}
```

`time` is the latest reading: the moment predicted from. Readings are in ascending order. Food `carbs`, `protein` and `fat` are grams and may be null. No data after `time` is ever sent.

### Response (version 1)

```json
{
  "version": 1,
  "series": [
    { "name": "IOB", "points": [{ "t": 1700000600, "mgdl": 105 }] },
    { "name": "UAM", "points": [{ "t": 1700000600, "mgdl": 120, "lower": 110, "upper": 130 }] }
  ]
}
```

- `series` must be non-empty; names are non-empty and unique; each has at least one point. `lower` and `upper` are optional and draw an uncertainty band.
- `version` may be omitted (treated as 1); any other value is rejected.
- To report a failure, return `{ "error": "message" }`.
- Non-numeric values or malformed JSON are rejected and shown as an error. Nothing invalid is drawn.

### Minimal JavaScript model

```js
function predict(requestJSON) {
  var r = JSON.parse(requestJSON);
  var last = r.readings[r.readings.length - 1].mgdl;
  return JSON.stringify({ series: [{ name: "Flat", points: [{ t: r.time + r.step, mgdl: last }] }] });
}
```

### Adapting oref0 / oref1

The oref0 `determine-basal` code takes IOB, current temp basal, glucose, profile, autosens and meal data and returns `predBGs` (`IOB`, `COB`, `UAM`, `ZT`). An adapter script converts this request into those inputs and each `predBGs` array into a series (5-minute steps starting at `time + step`). oref0 and oref1 differ by profile settings (`enableSMB_*`, `enableUAM`), so they are two registrations of one adapter with different settings.
