import XCTest
@testable import SmartTable

final class ManualScheduleTests: XCTestCase {
    private func lessons(_ day: String) -> [ScheduleItem] {
        ManualSchedule.window.items.filter { $0.day == day }
    }

    func testSemesterCoversEveryDateThroughDecember31Only() {
        let window = ManualSchedule.window
        XCTAssertEqual(window.days.first, "2026-09-21")
        XCTAssertEqual(window.days.last, "2026-12-31")
        XCTAssertEqual(window.days.count, 102)
        XCTAssertEqual(Set(window.days).count, 102)
        XCTAssertEqual(window.items.count, 404)
        XCTAssertEqual(Set(window.items.map(\.id)).count, window.items.count)
        XCTAssertEqual(window.origin, .manual)
        XCTAssertFalse(window.days.contains("2026-09-20"))
        XCTAssertFalse(window.days.contains("2027-01-01"))
        XCTAssertTrue(window.items.allSatisfy { window.days.contains($0.day) })
    }

    func testWeekAlternationUsesTheRequestedAnchorAcrossMonthBoundaries() {
        for day in ["2026-09-21", "2026-10-05", "2026-11-02", "2026-11-30", "2026-12-28", "2026-12-31"] {
            XCTAssertEqual(ManualSchedule.weekNumber(for: day), 2, day)
        }
        for day in ["2026-09-28", "2026-10-01", "2026-10-26", "2026-11-23", "2026-12-21"] {
            XCTAssertEqual(ManualSchedule.weekNumber(for: day), 1, day)
        }
        XCTAssertEqual(ManualSchedule.weekLabel(for: "2026-09-27"), "2-я неделя")
        XCTAssertEqual(ManualSchedule.weekLabel(for: "2026-09-28"), "1-я неделя")
    }

    func testOutOfSemesterAndInvalidDatesHaveNoWeek() {
        for day in ["2026-09-20", "2027-01-01", "2026-09-31", "2026-02-29", "2026-9-21", "garbage"] {
            XCTAssertNil(ManualSchedule.weekNumber(for: day), day)
            XCTAssertNil(ManualSchedule.weekLabel(for: day), day)
        }
    }

    func testAllSundaysAreCoveredButEmpty() throws {
        let formatter = CampusDate.formatter("yyyy-MM-dd")
        var sundayCount = 0
        for day in ManualSchedule.window.days {
            let date = try XCTUnwrap(formatter.date(from: day))
            if CampusDate.calendar.component(.weekday, from: date) == 1 {
                sundayCount += 1
                XCTAssertTrue(lessons(day).isEmpty, day)
            }
        }
        XCTAssertEqual(sundayCount, 14)
    }

    func testEmptySlotsStaySkippedAndExcelAddsPsychologySeminar() throws {
        let monday = lessons("2026-09-21")
        XCTAssertEqual(monday.compactMap(\.lessonNumber), [2, 3, 4, 5, 6, 7])
        XCTAssertEqual(lessons("2026-10-02").compactMap(\.lessonNumber), [1, 3, 4])
        XCTAssertEqual(lessons("2026-10-08").compactMap(\.lessonNumber), [1, 2, 3, 4, 5])
        let seminar = try XCTUnwrap(monday.first { $0.lessonNumber == 5 })
        XCTAssertEqual(seminar.subject, "Психология и педагогика")
        XCTAssertEqual(seminar.type, "Семинар")
        XCTAssertEqual(seminar.place, "3/321")
        XCTAssertEqual(seminar.timeStart, "14:15")
        XCTAssertEqual(seminar.timeEnd, "15:35")
        XCTAssertTrue(seminar.teacher.isEmpty)
    }

    func testLectureAndPracticeKeepTheirDifferentTeachers() throws {
        let lecture = try XCTUnwrap(lessons("2026-09-21").first { $0.subject == "Базы данных" })
        let lab = try XCTUnwrap(lessons("2026-10-02").first { $0.subject == "Базы данных" })
        XCTAssertEqual(lecture.teacher, "Кудрявцева Софья Владимировна")
        XCTAssertEqual(lab.teacher, "Комарова Юлиана Егоровна")
        let research = lessons("2026-09-28").filter { $0.subject == "Основы научных исследований" }
        XCTAssertEqual(research.map(\.teacher), ["Ершова Нина Остаповна", "Карпов Аркадий Антонович"])
        XCTAssertEqual(lessons("2026-12-21").first?.teacher, "Соколова Олеся Алексеевна")
    }

    func testUniversityCoursesUseExcelNamesAndLocationsOnBothWeeks() {
        for day in ["2026-09-21", "2026-09-28", "2026-12-28"] {
            let design = lessons(day).filter { $0.subject == "Графический дизайн и дизайн визуальных коммуникаций" }
            XCTAssertEqual(design.compactMap(\.lessonNumber), [6, 7])
            XCTAssertTrue(design.allSatisfy { $0.teacher == "Голубев Артём Остапович" && $0.place.contains("3/111") })
        }
        for day in ["2026-09-22", "2026-09-29", "2026-12-29"] {
            let english = lessons(day).filter { $0.subject == "Изучение английского языка" }
            XCTAssertEqual(english.compactMap(\.lessonNumber), [1, 2])
            XCTAssertTrue(english.allSatisfy { $0.teacher == "Орлова Марина Владимировна" && $0.place.contains("2/26") })
        }
        XCTAssertTrue(ManualSchedule.window.items.filter { $0.subject == "Университетский курс" }.allSatisfy { $0.requiresConfirmation == true })
    }

    func testSaturdayEquationsMoveFromFourthAndFifthToSixthAndSeventhSlots() {
        for day in ["2026-09-26", "2026-10-10", "2026-12-19"] {
            let equations = lessons(day).filter { $0.subject == "Дифференциальные уравнения" }
            XCTAssertEqual(equations.compactMap(\.lessonNumber), day < ManualSchedule.revisionDay ? [4, 5] : [6, 7])
            XCTAssertEqual(equations.map(\.timeStart), day < ManualSchedule.revisionDay ? ["12:45", "14:15"] : ["15:45", "17:15"])
            XCTAssertTrue(equations.allSatisfy { $0.teacher == "Зайцева Олеся Денисовна" })
        }
    }

    func testPracticeAndOnlineLecturesAreNotErasedByMissingExcelDetails() {
        for day in ["2026-09-22", "2026-09-29"] {
            let practice = lessons(day).filter { $0.subject == "Ознакомительная практика" }
            XCTAssertEqual(practice.compactMap(\.lessonNumber), [3, 4, 5, 6, 7])
            XCTAssertTrue(practice.allSatisfy { $0.teacher.isEmpty && $0.place.isEmpty })
        }
        XCTAssertEqual(lessons("2026-10-03").compactMap(\.lessonNumber), [6, 7, 8])
        XCTAssertTrue(lessons("2026-10-03").allSatisfy { $0.place == "Онлайн" })
        XCTAssertEqual(lessons("2026-09-26").first?.place, "Онлайн")
    }

    func testCancellationPreservesHistoryWithoutRepeatingOnOtherFridays() {
        let window = ManualSchedule.window
        XCTAssertEqual(lessons("2026-09-25").count, 3)
        XCTAssertEqual(window.cancelledDays, ["2026-09-25"])
        XCTAssertNotNil(window.dayNotes?["2026-09-25"])
        XCTAssertTrue(window.notificationItems.allSatisfy { $0.day != "2026-09-25" })
        XCTAssertEqual(window.notificationItems.filter { $0.day == "2026-10-09" }.count, 5)
        XCTAssertNil(window.dayNotes?["2026-10-09"])
    }

    func testUserSelectedInvestmentInFirstWeekAndKeptSecondWeekPsychology() {
        let window = ManualSchedule.window
        for day in ["2026-10-01", "2026-10-15", "2026-12-24"] {
            let selected = lessons(day).filter { $0.lessonNumber == 2 }
            XCTAssertEqual(selected.map(\.subject), ["Инвестируй правильно!"])
            XCTAssertTrue(selected.allSatisfy { $0.requiresConfirmation != true })
            XCTAssertNil(window.dayNotes?[day])
            XCTAssertEqual(window.notificationItems.filter { $0.day == day }.compactMap(\.lessonNumber), day < ManualSchedule.revisionDay ? [1, 2, 3] : [1, 2, 3, 4, 5])
        }
        for day in ["2026-09-24", "2026-10-08", "2026-12-31"] {
            XCTAssertEqual(lessons(day).first { $0.lessonNumber == 2 }?.subject, "Психологическая защита")
        }
        XCTAssertTrue(window.items.filter { $0.requiresConfirmation == true }.allSatisfy { $0.subject == "Университетский курс" && $0.lessonNumber == 1 })
        XCTAssertEqual(window.notificationItems.filter { $0.day == "2026-10-08" }.count, 4)
    }

    func testPhysicalEducationTypeUsesTheProvidedPortalSample() {
        let items = ManualSchedule.window.items.filter { $0.teacher == "Соколова Олеся Алексеевна" }
        XCTAssertEqual(items.count, 29)
        XCTAssertTrue(items.allSatisfy { $0.type == "Практическое" })
        XCTAssertTrue(ManualSchedule.window.items.filter { $0.type.isEmpty }.allSatisfy { $0.subject == "Английский язык" || $0.subject == "Русский язык как иностранный" })
    }

    func testLastPartialWeekIncludesDecember31ButStopsBeforeJanuary() {
        XCTAssertEqual(lessons("2026-12-31").compactMap(\.lessonNumber), [1, 2, 3, 4, 5])
        XCTAssertEqual(lessons("2026-12-31").first { $0.lessonNumber == 2 }?.subject, "Психологическая защита")
        XCTAssertTrue(lessons("2027-01-01").isEmpty)
        XCTAssertTrue(lessons("2027-01-04").isEmpty)
    }

    func testEighthSlotDoesNotInventClockTime() {
        let items = ManualSchedule.window.items.filter { $0.lessonNumber == 8 }
        XCTAssertEqual(items.count, 7)
        for item in items {
            XCTAssertTrue(item.timeStart.isEmpty)
            XCTAssertTrue(item.timeEnd.isEmpty)
            XCTAssertNil(CampusDate.start(of: item))
            XCTAssertEqual(item.place, "Онлайн")
        }
    }

    func testManualInstallationKeepsAccountGradesAndUnchangedTimestamp() throws {
        var previous = PortalSnapshot()
        previous.profile = StudentProfile(accountKey: "test", name: "Тест", identityUsesName: false)
        let grade = GradeItem(id: "g", subject: "Тест", type: "Зачёт", grade: "Зачтено", date: "25.09.2026", teacher: "", semester: "1")
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        previous.grades = CachedSection(value: [grade], fetchedAt: date, sources: [])
        previous.schedule = CachedSection(value: ScheduleWindow(days: ["2026-09-25"], items: []), fetchedAt: date, sources: [PortalConfiguration.scheduleURL])
        let installed = ManualSchedule.applying(to: previous, at: date)
        XCTAssertEqual(installed.profile, previous.profile)
        XCTAssertEqual(installed.grades?.value, [grade])
        XCTAssertEqual(installed.schedule?.value, ManualSchedule.window)
        XCTAssertTrue(try XCTUnwrap(installed.schedule).sources.isEmpty)
        let repeated = ManualSchedule.applying(to: installed, at: date.addingTimeInterval(3_600))
        XCTAssertEqual(repeated.schedule?.fetchedAt, date)
        let decoded = try JSONDecoder().decode(PortalSnapshot.self, from: JSONEncoder().encode(installed))
        XCTAssertEqual(decoded.schedule?.value, ManualSchedule.window)
    }

    func testExistingTwoWeekManualCacheUpgradesToFullSemester() {
        var previous = PortalSnapshot()
        let oldDate = Date(timeIntervalSince1970: 1_790_000_000)
        let newDate = oldDate.addingTimeInterval(60)
        previous.schedule = CachedSection(value: ScheduleWindow(days: ["2026-09-21", "2026-10-04"], items: [], origin: .manual), fetchedAt: oldDate, sources: [])
        let updated = ManualSchedule.applying(to: previous, at: newDate)
        XCTAssertEqual(updated.schedule?.value.days.count, 102)
        XCTAssertEqual(updated.schedule?.value.items.count, 404)
        XCTAssertEqual(updated.schedule?.fetchedAt, newDate)
    }

    func testOldCacheDecodesWithoutConfirmationFlag() throws {
        let json = #"{"days":["2026-09-21"],"items":[{"id":"legacy","day":"2026-09-21","timeStart":"09:30","timeEnd":"10:50","type":"","subject":"Тест","teacher":"","place":"","subgroup":""}]}"#
        let window = try JSONDecoder().decode(ScheduleWindow.self, from: Data(json.utf8))
        XCTAssertNil(window.origin)
        XCTAssertNil(window.dayNotes)
        XCTAssertNil(window.cancelledDays)
        XCTAssertNil(window.items.first?.lessonNumber)
        XCTAssertNil(window.items.first?.requiresConfirmation)
        XCTAssertEqual(window.notificationItems.count, 1)
    }
    func testOctoberRevisionAddsIntensivesAndPreservesEarlierHistory() {
        XCTAssertEqual(lessons("2026-09-23").compactMap(\.lessonNumber), [4])
        XCTAssertEqual(lessons("2026-10-07").compactMap(\.lessonNumber), [2, 3, 4])
        XCTAssertEqual(lessons("2026-10-09").compactMap(\.lessonNumber), [2, 3, 4, 5, 6])
        XCTAssertFalse(lessons("2026-10-05").contains { $0.lessonNumber == 5 })
        XCTAssertTrue(lessons("2026-09-21").contains { $0.lessonNumber == 5 })
    }
    func testOctoberFirstWeekUsesNewLabsAndForeignLanguageBlock() {
        let thursday = lessons("2026-10-15")
        XCTAssertEqual(thursday.first { $0.lessonNumber == 3 }?.subject, "Базы данных")
        XCTAssertEqual(thursday.first { $0.lessonNumber == 3 }?.place, "3/118")
        XCTAssertEqual(thursday.first { $0.lessonNumber == 4 }?.subject, "Информатизация общества")
        XCTAssertEqual(thursday.first { $0.lessonNumber == 5 }?.place, "3/16")
        XCTAssertEqual(lessons("2026-10-16").compactMap(\.lessonNumber), [1, 3])
        let russian = lessons("2026-10-17").filter { $0.subject == "Русский язык как иностранный" }
        XCTAssertEqual(russian.compactMap(\.lessonNumber), [2, 3, 4])
        XCTAssertTrue(russian.allSatisfy { $0.teacher == "А. В. Фёдорова" && $0.place == "2/26" })
    }

}
