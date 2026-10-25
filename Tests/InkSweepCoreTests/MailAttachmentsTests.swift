import XCTest
@testable import InkSweepCore

final class MailAttachmentsTests: FixtureTestCase {

    private func scanner(running: Set<String> = []) -> MailAttachmentsScanner {
        MailAttachmentsScanner(runningBundleIDs: { running })
    }

    func testFindsLargeAttachmentBlobs() throws {
        try write(4_000_000, to: "Library/Mail/V9/IMAP-user/Mailboxes/Inbox.mbox/Attachments/18/2/photo.zip")
        try write(500_000, to: "Library/Mail/V9/IMAP-user/Mailboxes/Inbox.mbox/Attachments/18/3/small.txt")
        try write(4_000_000, to: "Library/Mail/V9/IMAP-user/Mailboxes/Inbox.mbox/Messages/18.emlx")  // not an attachment

        let report = scanner().scan(context: context, knowledgeBase: .seed)

        XCTAssertEqual(report.findings.count, 1, "only files ≥1 MB inside Attachments subtrees")
        XCTAssertEqual(report.findings[0].category, .mailAttachments)
        XCTAssertTrue(report.findings[0].url.path.contains("Attachments"))
    }

    func testRunningMailIsSkippedWithWarning() throws {
        try write(4_000_000, to: "Library/Mail/V9/x/Attachments/1/2/big.pdf")
        let report = scanner(running: ["com.apple.mail"]).scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertTrue(report.warnings[0].contains("Mail"))
    }

    func testAbsentMailDataIsSilent() {
        let report = scanner().scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertTrue(report.warnings.isEmpty)
    }
}
