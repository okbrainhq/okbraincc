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

let hourly = BackupScheduleSettings(isEnabled: true, intervalMinutes: 60, retentionCount: 30)
let lastBackupAt0822 = date(year: 2026, month: 5, day: 26, hour: 8, minute: 22)

expect(
  hourly.nextAutomaticBackupDate(
    now: date(year: 2026, month: 5, day: 26, hour: 8, minute: 30),
    lastBackupDate: lastBackupAt0822,
    lastAttemptDate: nil
  ) == date(year: 2026, month: 5, day: 26, hour: 9, minute: 22),
  "next backup should be one hour after the last backup"
)

expect(
  hourly.nextAutomaticBackupDate(
    now: date(year: 2026, month: 5, day: 26, hour: 14, minute: 45),
    lastBackupDate: lastBackupAt0822,
    lastAttemptDate: nil
  ) == date(year: 2026, month: 5, day: 26, hour: 9, minute: 22),
  "next backup should not roll to tomorrow when an hourly backup is overdue"
)

expect(
  !hourly.shouldRunAutomatically(
    now: date(year: 2026, month: 5, day: 26, hour: 9, minute: 21),
    lastAttemptDate: nil,
    lastBackupDate: lastBackupAt0822,
    isActive: false
  ),
  "hourly backup should not run before the interval has elapsed"
)

expect(
  hourly.shouldRunAutomatically(
    now: date(year: 2026, month: 5, day: 26, hour: 9, minute: 22),
    lastAttemptDate: nil,
    lastBackupDate: lastBackupAt0822,
    isActive: false
  ),
  "hourly backup should run when one hour has elapsed"
)

expect(
  hourly.shouldRunAutomatically(
    now: date(year: 2026, month: 5, day: 26, hour: 14, minute: 45),
    lastAttemptDate: nil,
    lastBackupDate: lastBackupAt0822,
    isActive: false
  ),
  "hourly backup should be due now for a backup from 08:22"
)

expect(
  hourly.nextAutomaticBackupDate(
    now: date(year: 2026, month: 5, day: 26, hour: 14, minute: 45),
    lastBackupDate: nil,
    lastAttemptDate: nil
  ) == date(year: 2026, month: 5, day: 26, hour: 14, minute: 45),
  "backup should be due immediately when no previous backup exists"
)

expect(
  !hourly.shouldRunAutomatically(
    now: date(year: 2026, month: 5, day: 26, hour: 9, minute: 30),
    lastAttemptDate: date(year: 2026, month: 5, day: 26, hour: 9, minute: 0),
    lastBackupDate: lastBackupAt0822,
    isActive: false
  ),
  "automatic attempts should be throttled by the interval"
)

expect(
  hourly.shouldRunAutomatically(
    now: date(year: 2026, month: 5, day: 26, hour: 10, minute: 0),
    lastAttemptDate: date(year: 2026, month: 5, day: 26, hour: 9, minute: 0),
    lastBackupDate: lastBackupAt0822,
    isActive: false
  ),
  "automatic attempt throttle should expire after the interval"
)

let disabled = BackupScheduleSettings(isEnabled: false, intervalMinutes: 60, retentionCount: 30)
expect(
  !disabled.shouldRunAutomatically(
    now: date(year: 2026, month: 5, day: 26, hour: 10, minute: 0),
    lastAttemptDate: nil,
    lastBackupDate: lastBackupAt0822,
    isActive: false
  ),
  "disabled schedule should not run"
)

expect(
  !hourly.shouldRunAutomatically(
    now: date(year: 2026, month: 5, day: 26, hour: 10, minute: 0),
    lastAttemptDate: nil,
    lastBackupDate: lastBackupAt0822,
    isActive: true
  ),
  "active backup should block another automatic backup"
)

let ninetyMinutes = BackupScheduleSettings(isEnabled: true, intervalMinutes: 90, retentionCount: 30)
expect(ninetyMinutes.intervalLabel == "Every 1h 30m", "interval label should include hours and minutes")
