import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("Board")
        icon: "folder-sync"
        source: "configKanban.qml"
    }
    ConfigCategory {
        name: i18n("TimeWarrior")
        icon: "clock"
        source: "configTimew.qml"
    }
    ConfigCategory {
        name: i18n("Widget")
        icon: "timer"
        source: "configGeneral.qml"
    }
}
