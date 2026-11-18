import Foundation
import MapRendering

// Paints the map's sprite atlases ahead of time (MapRendering's `AtlasBaker`): the App's build
// runs it (App/Tools/bake-atlases.sh) and bundles what it writes, so the app reads its atlases
// at launch instead of painting them.
//
//     atlas-baker <directory>          paint and write decor.atlas, units.atlas, towns.atlas
//     atlas-baker --check <directory>  read them back as the app would

let arguments = Array(CommandLine.arguments.dropFirst())
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

if arguments.first == "--check" {
    guard arguments.count == 2 else { fail("usage: atlas-baker --check <directory>") }
    let result = AtlasBaker.check(URL(fileURLWithPath: arguments[1]))
    print(String(format: "read %@ in %.0f ms", result.matching.joined(separator: ", "), result.seconds * 1000))
    if result.matching.count < 3 { fail("atlas-baker: a bake is missing or was made from other code") }
} else {
    guard arguments.count == 1 else { fail("usage: atlas-baker <directory> | atlas-baker --check <directory>") }
    do {
        for baked in try AtlasBaker.bake(into: URL(fileURLWithPath: arguments[0])) {
            print(String(format: "%@: 2048x%d, %.1f MB, painted in %.0f ms", baked.file.lastPathComponent, baked.height,
                         Double(baked.bytes) / 1_048_576, baked.paintSeconds * 1000))
        }
    } catch {
        fail("atlas-baker: \(error)")
    }
}
