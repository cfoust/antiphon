import Foundation

// Mirror of src/agents.ts — the roster, ping notes, and timings. Timings are tuned a bit
// livelier than the web defaults so the done/summary flow is easy to observe in the spike.
enum AgentState { case working, done, summarizing, heard }

struct AgentDef {
    let id: String
    let name: String
    let hex: String // colour, for the radar
}

let AGENTS: [AgentDef] = [
    AgentDef(id: "atlas", name: "Atlas", hex: "#7aa2ff"),
    AgentDef(id: "echo", name: "Echo", hex: "#9aa6b8"),
    AgentDef(id: "wren", name: "Wren", hex: "#5fd0c5"),
    AgentDef(id: "cass", name: "Cass", hex: "#ffce6b"),
    AgentDef(id: "iris", name: "Iris", hex: "#c08bff"),
    AgentDef(id: "rook", name: "Rook", hex: "#ff9d7a"),
]

let PING_FREQS: [Float] = [523.25, 392.0, 587.33, 659.25, 783.99, 880.0]

let PING_INTERVAL = 2.6 // seconds between pings for a done agent
let LINGER_SECS = 1.5 // face a done agent this long → summary
let RECYCLE_SECS = 22.0 // after a summary is heard, back to working (web: 45)
let AUTO_FINISH_MIN = 10.0 // random gap before an agent finishes on its own (web: 27)
let AUTO_FINISH_MAX = 24.0 // (web: 66)

let DOWN_START = 8.0 // degrees of downward tilt where "all whisper" begins…
let DOWN_FULL = 26.0 // …and where it's fully engaged
