import TeebeCore
import Testing

/// Orbs for different worktrees run out of step; one worktree's orb never jumps.
@Suite("Thinking orb phase")
struct ThinkingOrbPhaseTests {
    let paths = ["/Users/me/code/app", "/Users/me/code/app-feature", "/Users/me/code/app-fix",
                 "/Users/me/code/other/worktree"]

    @Test("the same worktree always gets the same phase")
    func stable() {
        for path in paths {
            #expect(ThinkingOrbStyle.phaseOffset(for: path) == ThinkingOrbStyle.phaseOffset(for: path))
        }
        // A fixed hash, not the per-launch seeded one: the same value in every run.
        #expect(abs(ThinkingOrbStyle.phaseOffset(for: "/Users/me/code/app") - 1.462_175_609_447_933_7) < 1e-9)
    }

    @Test("different worktrees get different phases within one cycle")
    func distinct() {
        let phases = paths.map(ThinkingOrbStyle.phaseOffset(for:))
        #expect(Set(phases).count == paths.count)
        for phase in phases {
            #expect(phase >= 0 && phase < ThinkingOrbStyle.phaseSpan)
        }
    }

    @Test("two worktrees' orbs draw different frames at the same moment")
    func outOfStep() {
        for state in [ThinkingOrbState.solving, .breathing] {
            let style = ThinkingOrbStyle(state: state)
            let now = 1_000.0 * style.speed
            let first = style.frame(at: now + ThinkingOrbStyle.phaseOffset(for: paths[0]))
            let second = style.frame(at: now + ThinkingOrbStyle.phaseOffset(for: paths[1]))
            #expect(first.map(\.x) != second.map(\.x))
        }
    }
}
