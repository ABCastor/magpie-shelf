import Foundation

extension RouteFile {
    /// What Magpie writes the first time it looks for `routes.json`.
    ///
    /// JSON has no comments, so the header lives in `_readme` and each example
    /// carries a `note` — both are unknown keys, which the parser ignores by
    /// design, so they survive every edit. The two examples ship with
    /// `"enabled": false` so they teach the format without appearing in a menu
    /// until the owner has pointed them somewhere real.
    static var defaultContents: String {
        #"""
        {
          "version": 1,

          "_readme": [
            "Magpie routes — the files on a shelf, handed to a command you wrote.",
            "",
            "Right-click a shelf, or a tile, and pick Routes to run one. A route only ever starts from a click you made: no magpie:// link, no timer and no agent can start one.",
            "",
            "A route NEVER moves, renames, overwrites or deletes your files. Magpie hands the command the paths of the files to read, and that is all it can do to them. A route that wants to change something writes a NEW file instead.",
            "",
            "FIELDS",
            "  id                required, unique, e.g. copy-to-inbox",
            "  name              required, what the menu shows",
            "  symbol            optional SF Symbol name, e.g. tray.and.arrow.down",
            "  enabled           optional, default true. The examples below are false so they stay out of your menus until you edit them.",
            "  match             optional. Absent means the route is offered for any file. Give extensions, UTIs, or both: { \"extensions\": [\"pdf\"], \"utis\": [\"public.image\"] }. A route is offered only when EVERY selected file matches.",
            "  command           required, the FULL path to an executable, e.g. /bin/cp. There is no PATH lookup and no shell.",
            "  arguments         optional list of arguments. See the tokens below.",
            "  workingDirectory  optional, full path. Defaults to your home folder.",
            "  secrets           optional list of Keychain names, e.g. [\"GEMINI_API_KEY\"]. Add the values in Settings; Magpie passes each one to the command as an environment variable of the same name, and never prints or logs it.",
            "  timeoutSeconds    optional, default 120, maximum 3600. A command still running by then is stopped.",
            "  collectOutput     optional, default false. See {output} below.",
            "",
            "TOKENS you can use in arguments",
            "  {files}   must be an argument all on its own. It becomes one argument per selected file. Paths are passed straight to the command, so spaces, quotes and accents need no escaping — there is no shell in the way.",
            "  {output}  an empty folder Magpie makes for this run. Anything the command leaves there lands back on the shelf. Using the token switches collectOutput on by itself; set \"collectOutput\": true instead if your command would rather read the MAGPIE_OUTPUT_DIR environment variable.",
            "",
            "This file is read when Magpie starts and when you click Reload routes in Settings. Nothing in it runs at load time."
          ],

          "routes": [
            {
              "id": "example-copy-to-folder",
              "name": "Copy to Inbox",
              "symbol": "tray.and.arrow.down",
              "enabled": false,
              "command": "/bin/cp",
              "arguments": ["-R", "{files}", "/Users/CHANGE-ME/Inbox"],
              "note": "Copies the selected files into a folder, leaving the originals alone. Point the last argument at a folder that exists, then set enabled to true."
            },
            {
              "id": "example-run-a-script",
              "name": "Run My Script",
              "symbol": "terminal",
              "enabled": false,
              "match": { "extensions": ["m4a", "mp3", "wav"] },
              "command": "/Users/CHANGE-ME/bin/my-script.sh",
              "arguments": ["{files}", "--out", "{output}"],
              "secrets": ["GEMINI_API_KEY"],
              "timeoutSeconds": 900,
              "note": "Runs your own script over the selected audio files. The script gets GEMINI_API_KEY in its environment, and whatever it writes into the {output} folder comes back onto the shelf as new cards."
            }
          ]
        }

        """#
    }
}
