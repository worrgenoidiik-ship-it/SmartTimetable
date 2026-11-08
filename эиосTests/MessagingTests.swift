import XCTest
@testable import SmartTable

final class MessagingTests: XCTestCase {
    func testCourseTitlesFromTheScreenshotAreSplitReadably() {
        let full = CourseTitle("Базы данных ИС-О-25/1 (3 семестр, Комарова Юлиана Егоровна)")
        XCTAssertEqual(full.subject, "Базы данных")
        XCTAssertEqual(full.details, ["ИС-О-25/1", "3 семестр", "Комарова Юлиана Егоровна"])
        XCTAssertEqual(full.teacher, "Комарова Юлиана Егоровна")
        let plain = CourseTitle("Безопасность жизнедеятельности")
        XCTAssertEqual(plain.subject, "Безопасность жизнедеятельности")
        XCTAssertTrue(plain.details.isEmpty)
        XCTAssertNil(plain.teacher)
        let initials = CourseTitle("Психология и педагогика (Ж. Н. Донилова)")
        XCTAssertEqual(initials.teacher, "Ж. Н. Донилова")
        XCTAssertEqual(CourseTitle("Инвестируй правильно!").subject, "Инвестируй правильно!")
    }

    func testConversationsAndMessagesParse() throws {
        let list: [String: Any] = ["conversations": [[
            "id": 7, "name": "", "subname": "", "type": 1, "unreadcount": 2,
            "members": [["id": 501, "fullname": "Комарова Юлиана Егоровна",
                         "profileimageurl": "https://portal.ulsu.ru/theme/image.php/space/core/1/u/f1",
                         "isonline": true, "showonlinestatus": true]],
            "messages": [["id": 90, "useridfrom": 501, "text": "<p>Добрый день!<br>Отчёт до пятницы.</p>", "timecreated": 1_793_500_000]],
        ]]]
        let conversation = try XCTUnwrap(MessagingParser.conversations(list).first)
        XCTAssertEqual(conversation.title, "Комарова Юлиана Егоровна")
        XCTAssertEqual(conversation.unread, 2)
        XCTAssertEqual(conversation.members.first?.isOnline, true)
        XCTAssertEqual(conversation.lastMessage?.text, "Добрый день!\nОтчёт до пятницы.")
        let thread: [String: Any] = ["id": 7, "members": [], "messages": [
            ["id": 2, "useridfrom": 42, "text": "Спасибо", "timecreated": 1_793_500_100],
            ["id": 1, "useridfrom": 501, "text": "Привет", "timecreated": 1_793_500_000],
        ]]
        XCTAssertEqual(try MessagingParser.conversationMessages(thread).messages.map(\.id), [1, 2])
        XCTAssertThrowsError(try MessagingParser.conversations(["warnings": []]))
    }

    func testSendAndSearchResults() throws {
        let sent: [[String: Any]] = [["msgid": 15, "useridfrom": 42, "text": "Здравствуйте", "timecreated": 1_793_500_200, "conversationid": 7]]
        XCTAssertEqual(try MessagingParser.sentMessages(sent).first?.id, 15)
        let refused: [[String: Any]] = [["msgid": -1, "errormessage": "Пользователь ограничил сообщения"]]
        XCTAssertThrowsError(try MessagingParser.sentMessages(refused))
        let search: [String: Any] = ["contacts": [["id": 1, "fullname": "А"]], "noncontacts": [["id": 1, "fullname": "А"], ["id": 2, "fullname": "Б"]]]
        XCTAssertEqual(MessagingParser.searchResults(search).map(\.id), [1, 2])
    }

    func testAjaxErrorsSeparateSessionProblemsFromOthers() throws {
        XCTAssertEqual(try PortalParser.ajaxResult(Data(#"[{"error":false,"data":{"ok":1}}]"#.utf8)) as? [String: Int], ["ok": 1])
        for body in [#"[{"error":true,"exception":{"errorcode":"servicerequireslogin","message":"x"}}]"#,
                     #"{"error":"Неверный ключ сессии","errorcode":"invalidsesskey"}"#] {
            XCTAssertThrowsError(try PortalParser.ajaxResult(Data(body.utf8))) { error in
                guard case .loginRequired? = error as? PortalFailure else { return XCTFail("\(error)") }
            }
        }
        XCTAssertThrowsError(try PortalParser.ajaxResult(Data(#"[{"error":true,"exception":{"errorcode":"nopermissions","message":"Нет прав"}}]"#.utf8))) { error in
            guard case .unrecognized(let message)? = error as? PortalFailure else { return XCTFail("\(error)") }
            XCTAssertEqual(message, "Нет прав")
        }
    }

    func testUserIDComesFromTheUserMenu() {
        let html = #"<a href="/user/profile.php?id=5">чужой</a><div class="usermenu"><a href="https://portal.ulsu.ru/user/profile.php?id=42">Профиль</a></div>"#
        XCTAssertEqual(PortalParser.moodleUserID(in: html), 42)
        XCTAssertNil(PortalParser.moodleUserID(in: "<html>без меню</html>"))
    }
}
