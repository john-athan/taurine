import Foundation

/// The herd. 🐂
///
/// A bull has moods. When Taurine is idle the bull grazes; when it's holding
/// the line it gallops left→right, kicking up a dust trail of `»`. This is the
/// one thing no competitor has and none can copy without becoming a different
/// product: a caffeine tool with a face that tells you *why* you're awake.
enum Bull {

    /// Activate: bull accelerates from a standstill to a full gallop.
    /// Head indent GROWS each frame -> it travels left→right. Dust `»` lingers behind.
    static let run: [String] = [
"""
^__^
(oo)\\_____
(__)\\     )
  ||   ||
""",
"""
 ·   ^__^
     (Oo)\\_____
     (__)\\     )
      //     \\\\
""",
"""
»   ·    ^__^
         (Oo)\\_____
         (__)\\     )
         /_/     \\_\\
""",
"""
»»   ·      >^__^
            (@o)\\_____
            (__)\\     )
            /_/     \\_\\
""",
"""
»»»  ··       >^__^
              (@@)\\_____
              (__)\\     )
              _/ /   \\ \\_
""",
    ]

    /// Deactivate: bull decelerates at the right edge, stops, then dozes off.
    static let stop: [String] = [
"""
»»»  ··       >^__^
              (@@)\\_____
              (__)\\     )
              _/ /   \\ \\_
""",
"""
 »    ·       >^__^
              (Oo)\\_____
              (__)\\     )
              /=/     \\=\\
""",
"""
              ^__^
              (oo)\\_____
              (__)\\     )
                ||   ||
""",
"""
              ^__^     z
              (--)\\____ Z
              (__)\\     )
                ||   ||
""",
    ]

    /// A single calm bull for terminals (CLI command mode).
    static let grazing = """
      ^__^
      (oo)\\_____
      (__)\\     )
        ||   ||
"""

    /// A single charging bull for terminals.
    static let charging = """
»»»  >^__^
     (@@)\\_____
     (__)\\     )
     _/ /   \\ \\_
"""
}
