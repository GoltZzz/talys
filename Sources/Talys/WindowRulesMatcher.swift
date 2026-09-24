import Cocoa

public struct WindowRulesMatcher: Sendable {
    public let rules: [WindowRule]

    public init(rules: [WindowRule] = []) {
        self.rules = rules
    }

    /// Every rule that applies to the window, in config order.
    public func matches(appName: String?, windowTitle: String?) -> [WindowRule] {
        rules.filter { rule in
            var appMatches = true
            var titleMatches = true

            if let ruleApp = rule.app, !ruleApp.isEmpty {
                if let appName = appName {
                    appMatches = appName.localizedCaseInsensitiveContains(ruleApp)
                } else {
                    appMatches = false
                }
            }

            if let ruleTitle = rule.title, !ruleTitle.isEmpty {
                if let windowTitle = windowTitle {
                    titleMatches = windowTitle.localizedCaseInsensitiveContains(ruleTitle)
                } else {
                    titleMatches = false
                }
            }

            return (rule.app != nil || rule.title != nil) && appMatches && titleMatches
        }
    }
}
