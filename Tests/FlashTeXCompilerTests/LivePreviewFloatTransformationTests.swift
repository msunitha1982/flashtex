import XCTest
@testable import FlashTeX

final class LivePreviewFloatTransformationTests: XCTestCase {

    func testExplicitFigurePlacementsArePinned() {
        let source = """
        \\begin{figure}[h]one\\end{figure}
        \\begin{figure}[ht]two\\end{figure}
        \\begin{figure}[tb]three\\end{figure}
        \\begin{figure}[H]four\\end{figure}
        """

        XCTAssertEqual(LivePreviewFloatTransformer.pinSupportedFloats(in: source), """
        \\begin{figure}[H]one\\end{figure}
        \\begin{figure}[H]two\\end{figure}
        \\begin{figure}[H]three\\end{figure}
        \\begin{figure}[H]four\\end{figure}
        """)
    }

    func testTablesStarredFloatsAndMissingPlacementArePinned() {
        let source = """
        \\begin{table}body\\end{table}
        \\begin{table}[h]body\\end{table}
        \\begin{table*}[tb]body\\end{table*}
        \\begin{figure*}[ht]body\\end{figure*}
        """

        XCTAssertEqual(LivePreviewFloatTransformer.pinSupportedFloats(in: source), """
        \\begin{table}[H]body\\end{table}
        \\begin{table}[H]body\\end{table}
        \\begin{table*}[H]body\\end{table*}
        \\begin{figure*}[H]body\\end{figure*}
        """)
    }

    func testOnlySupportedFloatOpeningTokensChange() {
        let source = """
        [h] is ordinary text.
        % \\begin{figure}[h] comment
        \\begin{lstlisting}
        \\begin{figure}[h]
        \\end{lstlisting}
        \\begin{minipage}[h]body\\end{minipage}
        \\begin{figure} % comment before placement
        [tb]body\\end{figure}
        """

        XCTAssertEqual(LivePreviewFloatTransformer.pinSupportedFloats(in: source), """
        [h] is ordinary text.
        % \\begin{figure}[h] comment
        \\begin{lstlisting}
        \\begin{figure}[h]
        \\end{lstlisting}
        \\begin{minipage}[h]body\\end{minipage}
        \\begin{figure} % comment before placement
        [H]body\\end{figure}
        """)
    }

    func testCanonicalPreparationIsUnchangedWhileLivePreparationIsTransformed() {
        let source = """
        \\documentclass{article}
        \\begin{document}
        \\begin{figure}[h]\\caption{Keep this body unchanged}\\end{figure}
        \\end{document}
        """

        XCTAssertEqual(Compiler.preparedSource(source, livePreview: false), source)
        let preview = Compiler.preparedSource(source, livePreview: true)
        XCTAssertTrue(preview.contains("\\begin{figure}[H]\\caption{Keep this body unchanged}\\end{figure}"))
        XCTAssertTrue(preview.contains("% --- FlashTeX live-preview overrides ---"))
        XCTAssertEqual(source, """
        \\documentclass{article}
        \\begin{document}
        \\begin{figure}[h]\\caption{Keep this body unchanged}\\end{figure}
        \\end{document}
        """)
    }
}
