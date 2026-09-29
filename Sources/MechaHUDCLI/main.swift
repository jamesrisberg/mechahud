import Foundation
import HUDKit

// `mechahud <command> [key=value ...]`: talks to MechaHUD's MacHUD control socket.
// Shipped as MechaHUD.app/Contents/Helpers/mechahud.
//
//   mechahud hello
//   mechahud panel show id=dashboard
//   mechahud action name=approve id=claude:1234
//   mechahud quit

let usage = """
usage: mechahud <command> [key=value ...]
  hello | state | help | quit | subscribe
  panel show|hide|toggle id=dashboard
  panel mode id=dashboard full|compact|parked [edge= peek=]
  panel frame id=dashboard x= y= w= h=
  sessions                                every live session, plus whether mechaclaude can start one
  action name=open-session|approve|deny id=<sessionKey>
  action name=snapshot [path=<png>]
  settings get [key=]  |  settings set key=value ...

Environment: MECHAHUD_SOCKET picks the socket (a name, default mechahud, or an absolute path).

"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, !["-h", "--help"].contains(command) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(arguments.isEmpty ? 2 : 0)
}

let socketName = ProcessInfo.processInfo.environment["MECHAHUD_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? "mechahud"
let socketPath = socketName.hasPrefix("/") ? socketName : HUDSocket.path(for: socketName)

exit(HUDSocketClient.runCLI(path: socketPath, arguments: arguments, appName: "mechahud"))
