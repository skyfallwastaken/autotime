# Scratch: seed a realistic Autotime database (today + previous 13 days) including system helper rows.
import json, os, random, sqlite3, sys, datetime as dt

db_path = os.path.expanduser("~/Library/Application Support/Autotime/autotime.sqlite")
os.makedirs(os.path.dirname(db_path), exist_ok=True)
if os.path.exists(db_path):
    os.remove(db_path)
db = sqlite3.connect(db_path)
db.execute("CREATE TABLE activity(id INTEGER PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL, bundle TEXT NOT NULL, app TEXT NOT NULL, title TEXT NOT NULL, path TEXT NOT NULL)")
db.execute("CREATE INDEX activity_start ON activity(start)")
db.execute("CREATE INDEX activity_end ON activity(end)")

home = os.path.expanduser("~")
S = " ▸ "
apps = [
    ("com.apple.dt.Xcode", "Xcode", 26, [("StatsView.swift", f"file://{home}/Developer/autotime/Sources/Autotime/StatsView.swift"), ("Tracker.swift", f"file://{home}/Developer/autotime/Sources/Autotime/Tracker.swift"), ("Store.swift", f"file://{home}/Developer/autotime/Sources/Autotime/Store.swift")]),
    ("com.apple.Safari", "Safari", 18, [("Pull requests · autotime", "https://github.com/skyfallwastaken/autotime/pulls"), ("Charts | Apple Developer Documentation", "https://developer.apple.com/documentation/charts"), ("Hacker News", "https://news.ycombinator.com/"), ("SwiftUI Layout protocol", "https://developer.apple.com/documentation/swiftui/layout")]),
    ("com.google.Chrome", "Google Chrome", 10, [("Inbox (3) - Gmail", "https://mail.google.com/mail/u/0/#inbox"), ("Figma – Stats redesign", "https://www.figma.com/design/abc/stats"), ("YouTube", "https://www.youtube.com/watch?v=dQw4w9WgXcQ")]),
    ("com.apple.Terminal", "Terminal", 9, [("autotime — zsh", f"file://{home}/Developer/autotime/"), ("swift build", f"file://{home}/Developer/autotime/")]),
    ("com.tinyspeck.slackmacgap", "Slack", 8, [("general", f"Hack Club{S}#general"), ("autotime", f"Hack Club{S}#autotime"), ("DM", f"Hack Club{S}Mahad")]),
    ("com.apple.mail", "Mail", 6, [("Re: Weekly sync", f"Inbox{S}Re: Weekly sync"), ("Invoice October", f"Inbox{S}Invoice October")]),
    ("com.apple.MobileSMS", "Messages", 4, [("Alex", f"Alex")]),
    ("com.apple.Notes", "Notes", 4, [("Ideas", f"iCloud{S}Ideas{S}Autotime roadmap")]),
    ("com.apple.finder", "Finder", 3, [("Downloads", f"file://{home}/Downloads/")]),
    ("com.apple.systempreferences", "System Settings", 2, [("Privacy & Security", ""), ("Displays", "")]),
    ("com.microsoft.VSCode", "Visual Studio Code", 5, [("README.md — autotime", f"file://{home}/Developer/autotime/README.md")]),
    ("com.apple.Preview", "Preview", 1, [("receipt.pdf", f"file://{home}/Documents/receipt.pdf")]),
]
helpers = [
    ("com.apple.UserNotificationCenter", "UserNotificationCenter"),
    ("com.apple.dock", "Dock"),
    ("com.apple.SecurityAgent", "SecurityAgent"),
    ("com.apple.coreservices.uiagent", "CoreServicesUIAgent"),
    ("com.apple.loginwindow", "loginwindow"),
    ("com.apple.WebKit.PluginHost", "WebKit Plug-in Host"),
]
weights = [a[2] for a in apps]
random.seed(7)
now = dt.datetime.now()
today = now.replace(hour=0, minute=0, second=0, microsecond=0)
expected = {}
for back in range(14):
    day = today - dt.timedelta(days=back)
    if day.weekday() == 6 and back > 0:
        continue  # a quiet Sunday
    t = day.replace(hour=8, minute=40) + dt.timedelta(minutes=random.randint(0, 40))
    end_of_day = day.replace(hour=18, minute=10) + dt.timedelta(minutes=random.randint(0, 50))
    visible = hidden = 0.0
    while t < end_of_day:
        if t.hour == 12 and t.minute < 40:
            t = t.replace(minute=45)  # lunch
        if random.random() < 0.06:
            bundle, name = random.choice(helpers)
            d = random.randint(4, 60)
            db.execute("INSERT INTO activity(start,end,bundle,app,title,path) VALUES(?,?,?,?,?,?)", (t.timestamp(), t.timestamp() + d, bundle, name, "", ""))
            hidden += d
            t += dt.timedelta(seconds=d)
        bundle, name, _, items = random.choices(apps, weights)[0]
        title, path = random.choice(items)
        d = random.randint(30, 1500)
        db.execute("INSERT INTO activity(start,end,bundle,app,title,path) VALUES(?,?,?,?,?,?)", (t.timestamp(), t.timestamp() + d, bundle, name, title, path))
        visible += d
        t += dt.timedelta(seconds=d + random.choice([0, 0, 0, 5, 40]))
    expected[day.strftime("%Y-%m-%d")] = {"visible_min": round(visible / 60, 1), "hidden_min": round(hidden / 60, 1)}
db.commit()
print(json.dumps(expected, indent=1))
