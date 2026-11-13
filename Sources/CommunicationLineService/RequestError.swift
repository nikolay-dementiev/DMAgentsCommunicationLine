/// A request that cannot be served because of how it is written, before any service is asked.
enum RequestError: Error, Equatable {
  case badRequest(String)
  case tokenRequired
}
