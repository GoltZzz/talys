import Cocoa

public struct WindowRulesMatcher: Sendable {
    public let rules: [WindowRule]

    public init(rules: [WindowRule] = []) {
        self.rules = rules
    }

    public func match(appName: String?, windowTitle: String?) -> WindowRule? {
        for rule in rules {
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

            if (rule.app != nil || rule.title != nil) && appMatches && titleMatches {
                return rule
            }
        }
        return nil
    }
}
