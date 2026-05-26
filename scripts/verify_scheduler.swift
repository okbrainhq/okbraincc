import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("Scheduler verification failed: \(message)\n".utf8))
  exit(1)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    fail(message)
  }
}

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
  let result = DateComponents(
    calendar: calendar,
    timeZone: calendar.timeZone,
    year: year,
    month: month,
    day: day,
    hour: hour,
    minute: minute
  ).date

  guard let result else {
    fail("could not build date")
  }

  return result
}

let dueAtTime = BackupScheduleSettings(isEnabled: true, hour: 10, minute: 30, retentionCount: 30)
expect(
  dueAtTime.shouldRunAutomatically(
    now: date(year: 2026, month: 5, day: 26, hour: 10, minute: 30),
    lastAttemptDay: nil,
    lastBackupDate: nil,
    isActive: false,
    calendar: calendar
  ),
  "backup should run at the scheduled time"
)

let catchUp = BackupScheduleSettings(isEnabled: true, hour: 3, minute: 30, retentionCount: 30)
expect(
  catchUp.shouldRunAutomatically(
    now: date(year: 2026, month: 5, day: 26, hour: 10, minute: 0),
    lastAttemptDay: nil,
    lastBackupDate: nil,
    isActive: false,
    calendar: calendar
  ),
  "backup should catch up after the scheduled time"
)

expect(
  catchUp.nextAutomaticBackupDate(
    now: date(year: 2026, month: 5, day: 26, hour: 10, minute: 0),
    lastBackupDate: date(year: 2026, month: 5, day: 26, hour: 9, minute: 0),
    calendar: calendar
  ) == date(year: 2026, month: 5, day: 27, hour: 9, minute: 0),
  "next backup should be anchored to the last backup time"
)

expect(
  catchUp.nextAutomaticBackupDate(
    now: date(year: 2026, month: 5, day: 26, hour: 2, minute: 0),
    lastBackupDate: nil,
    calendar: calendar
  ) == date(year: 2026, month: 5, day: 26, hour: 3, minute: 30),
  "first backup should use configured time when no previous backup exists"
)

expect(
  !dueAtTime.shouldRunAutomatically(
    now: date(year: 2026, month: 5, day: 26, hour: 10, minute: 29),
    lastAttemptDay: nil,
    lastBackupDate: nil,
    isActive: false,
    calendar: calendar
  ),
  "backup should not run before the scheduled time"
)

expect(
  !catchUp.shouldRunAutomatically(
    now: date(year: 2026, month: 5, day: 26, hour: 10, minute: 0),
    lastAttemptDay: "2026-05-26",
    lastBackupDate: nil,
    isActive: false,
    calendar: calendar
  ),
  "backup should run only once per day"
)

let disabled = BackupScheduleSettings(isEnabled: false, hour: 3, minute: 30, retentionCount: 30)
expect(
  !disabled.shouldRunAutomatically(
    now: date(year: 2026, month: 5, day: 26, hour: 10, minute: 0),
    lastAttemptDay: nil,
    lastBackupDate: nil,
    isActive: false,
    calendar: calendar
  ),
  "disabled schedule should not run"
)

expect(
  !catchUp.shouldRunAutomatically(
    now: date(year: 2026, month: 5, day: 26, hour: 10, minute: 0),
    lastAttemptDay: nil,
    lastBackupDate: nil,
    isActive: true,
    calendar: calendar
  ),
  "active backup should block another automatic backup"
)

expect(
  !catchUp.shouldRunAutomatically(
    now: date(year: 2026, month: 5, day: 26, hour: 10, minute: 0),
    lastAttemptDay: nil,
    lastBackupDate: date(year: 2026, month: 5, day: 26, hour: 9, minute: 0),
    isActive: false,
    calendar: calendar
  ),
  "backup should not be due until 24 hours after the last backup"
)

expect(
  catchUp.shouldRunAutomatically(
    now: date(year: 2026, month: 5, day: 26, hour: 10, minute: 0),
    lastAttemptDay: nil,
    lastBackupDate: date(year: 2026, month: 5, day: 25, hour: 9, minute: 59),
    isActive: false,
    calendar: calendar
  ),
  "backup should be due when 24 hours passed since the last backup"
)
