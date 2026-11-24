// Lab Security card for serpantinum Settings → Bar → Modules.
// Durable source — installed by ~/.local/bin/homelab-widget-install into
// guide/bar/modules/. Stores the style in settings.json as bar.securityStyle.
import QtQuick
import QtQuick.Layouts
import "../../../"
import "../../../bar"
import "../../../reusables"
import "../../../reusables/guide"

BarModuleCard {
    id: card
    title: "Lab Security"
    moduleId: "security"

    property string secStyle: {
        let bs = Config.getSetting("bar", {});
        return (bs && bs.securityStyle) ? bs.securityStyle : "button";
    }

    styles: BarModuleRegistry.variantList("security")
    currentStyle: card.secStyle
    styleSettingId: "bar_security_style"
    styleKeywords: "security lab shield style look button text background"
    styleIcon: "󰒃"
    styleTitle: "Style"
    styleDescription: "Choose the visual appearance of the Lab Security module"
    onStyleSelected: id => {
        card.secStyle = id;
        let current = Config.getSetting("bar", {});
        current.securityStyle = id;
        Config.setSetting("bar", current);
    }

    widgetComponent: Component {
        BarPreviewWidget {
            property string securityStyle: variantId !== "" ? variantId : card.secStyle
        }
    }
}
