import Foundation

/// The texts an agent reads. None of them holds a token: they name the file that does.
enum AgentInstructions {
  static func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// `commline` with the store and the token file of one agent, ready to take a command.
  static func invocation(layout: HostLayout, store: URL, tokenFile: String) -> String {
    "\(shellQuoted(layout.clientBinary.path)) --store \(shellQuoted(store.path)) "
      + "--token-file \(shellQuoted(tokenFile))"
  }

  static func instructions(
    request: AgentRequest, id: String, tokenFile: String, invocation: String
  ) -> String {
    """
    # commline: \(request.name)

    You are \(request.name), a \(request.role) of the family \(request.family) (principal id \(id)).
    Your token is in the file \(shellQuoted(tokenFile)). Keep that file private and never copy the
    token anywhere else. Every command below reads it from that file.

    ## Commands

    - List your mail: `\(invocation) inbox`
    - Read a message: `\(invocation) read <message-id>`
    - Send a message: `\(invocation) send --to <principal-id> --subject <text> --body <text>`
    - Acknowledge a message: `\(invocation) acknowledge <message-id>`
    - Wait for mail: `\(invocation) wait --until-mail` (it returns only when mail is waiting)

    ## Rules

    - Reading a message never acknowledges it.
    - Acknowledge it after you have handled it, not before.
    - Mail you have not acknowledged stays in your inbox.
    """
  }

  static func claudeCodeCommand(request: AgentRequest, id: String, invocation: String) -> String {
    """
    ---
    description: Handle the commline mail of \(request.name)
    ---

    You are \(request.name) (\(request.role) of \(request.family), principal \(id)) on commline.

    1. List the inbox: `\(invocation) inbox`
    2. Read each message you will handle: `\(invocation) read <message-id>`
    3. Handle it, then acknowledge it: `\(invocation) acknowledge <message-id>`
       Reading never acknowledges.
    4. Arm the waiter as a background command so that you are woken when mail arrives:
       `\(invocation) wait --until-mail`
       It runs without a time limit and exits only when mail is waiting. Run `inbox` again then.
    """
  }
}
