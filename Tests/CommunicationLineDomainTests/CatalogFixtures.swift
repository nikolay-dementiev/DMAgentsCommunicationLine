import CommunicationLineDomain
import Foundation

/// Builds catalog resource text from setting entries, so tests state only what they vary.
func catalogData(_ settings: String...) -> Data {
  Data(#"{"settings":[\#(settings.joined(separator: ","))]}"#.utf8)
}

func integerSetting(
  key: String = "demo.limit", defaultValue: Int = 5,
  range: String = #""range":{"min":1,"max":10},"#,
  scopes: String = #"["global","family","principal"]"#
) -> String {
  #"{"key":"\#(key)","type":"integer","default":\#(defaultValue),\#(range)"scopes":\#(scopes),"description":"A demo limit."}"#
}
