import XCTest
@testable import SmartTable

/// Structure of a real attempt page (quiz_attempt.html), with identifiers replaced.
final class QuizTests: XCTestCase {
    private let url = URL(string: "https://portal.ulsu.ru/mod/quiz/attempt.php?attempt=1&cmid=2")!

    private func page(_ questions: String, next: String = "Следующая страница", previous: Bool = false) -> String {
        """
        <html><body><div id="page-header"><h1>Маркетинг</h1></div><section id="region-main">
        <form action="https://portal.ulsu.ru/mod/quiz/processattempt.php?cmid=2" method="post" enctype="multipart/form-data" id="responseform"><div>
        \(questions)
        <div class="submitbtns">\(previous ? "<input type=\"submit\" name=\"previous\" value=\"Предыдущая страница\">" : "")<input type="submit" name="next" value="\(next)"></div>
        <input type="hidden" name="attempt" value="1"><input type="hidden" name="thispage" value="0"><input type="hidden" name="nextpage" value="1">
        <input type="hidden" name="timeup" value="0"><input type="hidden" name="sesskey" value="AbCdEf1234"><input type="hidden" name="scrollpos" value=""><input type="hidden" name="slots" value="1">
        </div></form></section><script>M.mod_quiz.timer.init(Y, 900, 0);</script></body></html>
        """
    }

    private let multichoice = """
    <div id="question-5-1" class="que multichoice deferredfeedback notyetanswered"><div class="info"><h3 class="no">Вопрос <span class="qno">1</span></h3><div class="state">Пока нет ответа</div><div class="grade">Балл: 1,00</div>
    <div class="questionflag editable"><input type="hidden" name="q5:1_:flagged" value="0"><input type="image" class="questionflagimage" src="x"></div></div>
    <div class="content"><div class="formulation clearfix"><input type="hidden" name="q5:1_:sequencecheck" value="1"><div class="qtext">Какие факторы не входят в маркетинговую среду фирмы:</div>
    <div class="ablock"><div class="prompt">Выберите один или несколько ответов:</div><div class="answer">
    <div class="r0"><input type="hidden" name="q5:1_choice0" value="0"><input type="checkbox" name="q5:1_choice0" value="1" id="q5:1_choice0"><label for="q5:1_choice0"><span class="answernumber">a. </span>Мезофакторы.</label></div>
    <div class="r1"><input type="hidden" name="q5:1_choice1" value="0"><input type="checkbox" name="q5:1_choice1" value="1" id="q5:1_choice1"><label for="q5:1_choice1"><span class="answernumber">b. </span>Микрофакторы.</label></div>
    </div></div></div></div></div>
    """

    func testMultipleChoiceAndPayloadOrder() throws {
        guard case .attempt(let attempt) = try QuizParser.parse(html: page(multichoice), url: url) else { return XCTFail("not an attempt") }
        XCTAssertEqual(attempt.title, "Маркетинг")
        XCTAssertEqual(attempt.timeLeft, 900)
        let question = try XCTUnwrap(attempt.questions.first)
        XCTAssertEqual(question.number, "1")
        XCTAssertEqual(question.text, "Какие факторы не входят в маркетинговую среду фирмы:")
        guard case .multiple(let options) = question.answer else { return XCTFail("\(question.answer)") }
        XCTAssertEqual(options.map(\.label), ["a. Мезофакторы.", "b. Микрофакторы."])
        let items = attempt.payload(values: [:], checked: [options[1].id], button: attempt.next)
        let pairs = items.map { "\($0.name)=\($0.value ?? "")" }
        // The browser sends the hidden «0» first and then the ticked «1»: Moodle keeps the last value.
        let hidden = try XCTUnwrap(pairs.firstIndex(of: "q5:1_choice1=0"))
        let ticked = try XCTUnwrap(pairs.firstIndex(of: "q5:1_choice1=1"))
        XCTAssertLessThan(hidden, ticked)
        XCTAssertFalse(pairs.contains("q5:1_choice0=1"))
        XCTAssertEqual(pairs.last, "next=Следующая страница")
        XCTAssertTrue(pairs.contains("sesskey=AbCdEf1234"))
        XCTAssertTrue(attempt.payload(values: [:], checked: [], button: nil, timeUp: true).contains(URLQueryItem(name: "timeup", value: "1")))
    }

    func testSingleChoiceTextAndUnsupported() throws {
        let questions = """
        <div id="question-5-2" class="que multichoice"><span class="qno">2</span><div class="qtext">Столица?</div>
        <input type="radio" name="q5:2_answer" value="0" id="a0"><label for="a0">Москва</label>
        <input type="radio" name="q5:2_answer" value="1" id="a1" checked="checked"><label for="a1">Казань</label>
        <input type="radio" name="q5:2_answer" value="-1" id="a2"><label for="a2">Очистить мой выбор</label></div>
        <div id="question-5-3" class="que essay"><span class="qno">3</span><div class="qtext">Опишите</div><textarea name="q5:3_answer">черновик</textarea></div>
        <div id="question-5-4" class="que ddimageortext"><span class="qno">4</span><div class="qtext">Перетащите</div></div>
        """
        guard case .attempt(let attempt) = try QuizParser.parse(html: page(questions, previous: true), url: url) else { return XCTFail() }
        guard case .single(let name, let options) = attempt.questions[0].answer else { return XCTFail() }
        XCTAssertEqual(options.map(\.label), ["Москва", "Казань"])            // «Очистить мой выбор» is not an answer
        XCTAssertEqual(attempt.initialState.values[name], "1")              // a ticked radio is kept
        XCTAssertEqual(attempt.initialState.values["q5:3_answer"], "черновик")
        guard case .text(_, let multiline) = attempt.questions[1].answer else { return XCTFail() }
        XCTAssertTrue(multiline)
        XCTAssertTrue(attempt.hasUnsupported)
        XCTAssertEqual(attempt.previous?.name, "previous")
        let items = attempt.payload(values: [name: "0", "q5:3_answer": "a&b=c"], checked: [], button: attempt.next)
        XCTAssertTrue(items.contains(URLQueryItem(name: name, value: "0")))
        XCTAssertFalse(items.contains(URLQueryItem(name: name, value: "1")))
        XCTAssertTrue(PortalClient.formEncoded(items).contains("q5%3A3_answer=a%26b%3Dc"))
    }

    func testSummaryAndFinishForm() throws {
        let html = """
        <html><body><section id="region-main"><table class="generaltable quizsummaryofattempt"><tbody>
        <tr><td>1</td><td>Ответ сохранен</td></tr><tr><td>2</td><td>Пока нет ответа</td></tr></tbody></table>
        <form method="get" action="https://portal.ulsu.ru/mod/quiz/attempt.php"><input type="hidden" name="attempt" value="1"><input type="hidden" name="cmid" value="2"><button>Вернуться к попытке</button></form>
        <form method="post" action="https://portal.ulsu.ru/mod/quiz/processattempt.php"><input type="hidden" name="attempt" value="1"><input type="hidden" name="finishattempt" value="1"><input type="hidden" name="sesskey" value="AbCdEf1234"><button>Отправить всё и завершить тест</button></form>
        </section></body></html>
        """
        guard case .summary(let summary) = try QuizParser.parse(html: html, url: url) else { return XCTFail() }
        XCTAssertEqual(summary.rows.map(\.status), ["Ответ сохранен", "Пока нет ответа"])
        XCTAssertEqual(summary.finishAction?.path, "/mod/quiz/processattempt.php")
        XCTAssertTrue(summary.finishFields.contains(URLQueryItem(name: "finishattempt", value: "1")))
        XCTAssertEqual(summary.returnURL?.absoluteString, "https://portal.ulsu.ru/mod/quiz/attempt.php?attempt=1&cmid=2")
    }

    func testIndependentWorkLabel() {
        let work = CourseActivity(id: "1", name: "Самостоятельная работа №2", kind: "quiz", info: "", url: nil)
        let test = CourseActivity(id: "2", name: "Итоговый тест", kind: "quiz", info: "", url: nil)
        XCTAssertEqual(work.kindLabel, "Самостоятельная работа")
        XCTAssertEqual(test.kindLabel, "Тест")
    }
}
