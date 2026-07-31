// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

// lookout-marine on the reMarkable: the chart core behind a Qt Quick shell,
// drawn for e-ink. The chrome follows the Apple shell (macos/LookoutMarine) —
// same readouts, same pick report, same settings — in Qt Quick instead of
// SwiftUI, and monochrome instead of colour.

#include <QCommandLineParser>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QScreen>
#include <QSize>
#include <QTimer>
#include <QUrl>

#include "lookoutchart.h"

#if defined(__GLIBC__)
#include <csignal>
#include <cstdio>
#include <execinfo.h>
#include <unistd.h>
// A symbolic backtrace on a crash, so a segfault on the tablet is diagnosable
// without gdb. The binary keeps its symbols and links -rdynamic for the names.
static void crashHandler(int sig) {
    void* frames[64];
    int n = backtrace(frames, 64);
    fprintf(stderr, "\n*** lookout-marine caught signal %d — backtrace: ***\n", sig);
    backtrace_symbols_fd(frames, n, STDERR_FILENO);
    fflush(stderr);
    signal(sig, SIG_DFL);
    raise(sig);
}
static void installCrashHandler() {
    signal(SIGSEGV, crashHandler);
    signal(SIGABRT, crashHandler);
    signal(SIGBUS, crashHandler);
    signal(SIGFPE, crashHandler);
}
#else
static void installCrashHandler() {}
#endif

// Headless capture for verification: with LOOKOUT_SHOT=<path> set, grab the
// window once it has settled and quit. No effect on a normal run. This is what
// the screenshot protocol drives (docs/docs/developer-guide/screenshots.md).
static void maybeScheduleScreenshot(QQmlApplicationEngine* engine) {
    const QByteArray shot = qgetenv("LOOKOUT_SHOT");
    if (shot.isEmpty())
        return;
    const int delayMs = qEnvironmentVariableIntValue("LOOKOUT_SHOT_DELAY") > 0
                            ? qEnvironmentVariableIntValue("LOOKOUT_SHOT_DELAY")
                            : 3000;
    QTimer::singleShot(delayMs, engine, [engine, shot]() {
        if (engine->rootObjects().isEmpty()) {
            QCoreApplication::exit(2);
            return;
        }
        auto* win = qobject_cast<QQuickWindow*>(engine->rootObjects().first());
        if (win)
            win->grabWindow().save(QString::fromUtf8(shot));
        QCoreApplication::quit();
    });
}

// Point the engine at the monochrome "ink" S-52 colour profile. The reMarkable
// has no backlight, so day/dusk/night are moot; the engine reads
// TILE57_COLORPROFILE and recolours the whole base map from it. The file ships
// beside the binary. If it is missing — or the variable is already set — leave
// it alone and the engine falls back to its embedded colour profile.
static void useInkColorProfile() {
    if (qEnvironmentVariableIsSet("TILE57_COLORPROFILE"))
        return;
    const QString ink =
        QCoreApplication::applicationDirPath() + QStringLiteral("/colorProfile.ink.xml");
    if (QFileInfo::exists(ink))
        qputenv("TILE57_COLORPROFILE", QFile::encodeName(ink));
}

int main(int argc, char* argv[]) {
    installCrashHandler();
    QGuiApplication app(argc, argv);
    QGuiApplication::setApplicationName(QStringLiteral("Lookout Marine"));
    QGuiApplication::setOrganizationName(QStringLiteral("lookout"));
    QGuiApplication::setApplicationVersion(lookout::version());

    // Must precede any open, so the engine parses the ink profile first.
    useInkColorProfile();

    // A neutral base style, fully re-skinned for e-ink; no platform theming.
    QQuickStyle::setStyle(QStringLiteral("Basic"));

    QCommandLineParser parser;
    parser.setApplicationDescription(
        QStringLiteral("Nautical charts on the reMarkable, from baked tile57 archives"));
    parser.addHelpOption();
    parser.addVersionOption();
    parser.addPositionalArgument(QStringLiteral("chart"),
                                 QStringLiteral("A baked .pmtiles archive, or a folder of them"));
    parser.process(app);

    // LOOKOUT_OPEN matches the other shells' env knob; a positional argument wins.
    QString chartPath = qEnvironmentVariable("LOOKOUT_OPEN");
    const QStringList positional = parser.positionalArguments();
    if (!positional.isEmpty())
        chartPath = positional.first();

    // Where the chart picker starts browsing: the chart's own folder.
    QString chartsDir;
    if (!chartPath.isEmpty()) {
        const QFileInfo fi(chartPath);
        chartsDir = fi.isDir() ? fi.absoluteFilePath() : fi.absolutePath();
    }

    QQmlApplicationEngine engine;
    QQmlContext* ctx = engine.rootContext();
    ctx->setContextProperty(QStringLiteral("appChartPath"), chartPath);
    ctx->setContextProperty(QStringLiteral("appChartsDir"), chartsDir);
    ctx->setContextProperty(QStringLiteral("appVersion"), lookout::version());
    ctx->setContextProperty(QStringLiteral("appOpenSettings"),
                            qEnvironmentVariableIsSet("LOOKOUT_OPEN_SETTINGS"));

    // reMarkable's own Qt platform plugin. It drives fullscreen and turns off
    // animations — an e-ink panel cannot show them, and each one costs a refresh.
    const bool eink = app.platformName() == QLatin1String("epaper");
    ctx->setContextProperty(QStringLiteral("appEink"), eink);
    ctx->setContextProperty(QStringLiteral("appFullscreen"),
                            eink || qEnvironmentVariableIsSet("LOOKOUT_FULLSCREEN"));

    // The epaper platform ignores Window.FullScreen, so hand QML the real screen
    // size to size the window explicitly. LOOKOUT_SIZE=WxH overrides it.
    QSize screen(1404, 1872); // the rM2 panel
    if (QScreen* s = QGuiApplication::primaryScreen())
        if (!s->geometry().size().isEmpty())
            screen = s->geometry().size();
    const QByteArray sizeEnv = qgetenv("LOOKOUT_SIZE");
    if (sizeEnv.contains('x')) {
        const QList<QByteArray> wh = sizeEnv.split('x');
        if (wh.size() == 2 && wh[0].toInt() > 0 && wh[1].toInt() > 0)
            screen = QSize(wh[0].toInt(), wh[1].toInt());
    }
    ctx->setContextProperty(QStringLiteral("appScreenW"), screen.width());
    ctx->setContextProperty(QStringLiteral("appScreenH"), screen.height());

    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        []() { QCoreApplication::exit(-1); }, Qt::QueuedConnection);

#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
    engine.loadFromModule("LookoutMarine", "Main");
#else
    // Qt 6.4 (Debian bookworm's, used by the container build) has no
    // loadFromModule — load Main by its module resource URL instead.
    engine.load(QUrl(QStringLiteral("qrc:/qt/qml/LookoutMarine/qml/Main.qml")));
#endif
    maybeScheduleScreenshot(&engine);

    return app.exec();
}
