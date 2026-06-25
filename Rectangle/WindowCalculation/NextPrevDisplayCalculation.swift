/// NextPrevDisplayCalculation.swift

import Cocoa

class NextPrevDisplayCalculation: WindowCalculation {
    
    override func calculate(_ params: WindowCalculationParameters) -> WindowCalculationResult? {
        let usableScreens = params.usableScreens
        
        guard usableScreens.numScreens > 1 else { return nil }

        var screen: NSScreen?
        
        if params.action == .nextDisplay || params.action == .nextDisplayMaxHeight {
            screen = usableScreens.adjacentScreens?.next
        } else if params.action == .previousDisplay {
            screen = usableScreens.adjacentScreens?.prev
        }

        if let screen = screen {
            let rectParams = params.asRectParams(visibleFrame: screen.adjustedVisibleFrame(params.ignoreTodo))

            // nextDisplayMaxHeight always forces max-height on the destination, so it
            // bypasses the "re-apply the last action" match path entirely.
            if params.action != .nextDisplayMaxHeight,
               Defaults.attemptMatchOnNextPrevDisplay.userEnabled {
                if let lastAction = params.lastAction,
                   let calculation = WindowCalculationFactory.calculationsByAction[lastAction.action] {
                    
                    AppDelegate.windowHistory.lastRectangleActions.removeValue(forKey: params.window.id)
                    
                    let newCalculationParams = RectCalculationParameters(
                        window: rectParams.window,
                        visibleFrameOfScreen: rectParams.visibleFrameOfScreen,
                        action: lastAction.action,
                        lastAction: nil)
                    let rectResult = calculation.calculateRect(newCalculationParams)
                    
                    return WindowCalculationResult(rect: rectResult.rect, screen: screen, resultingAction: lastAction.action)
                }
            }
            
            let rectResult = calculateRect(rectParams)
            let resultingAction: WindowAction = rectResult.resultingAction ?? params.action
            return WindowCalculationResult(rect: rectResult.rect, screen: screen, resultingAction: resultingAction)
        }
        
        return nil
    }
    
    override func calculateRect(_ params: RectCalculationParameters) -> RectResult {
        if params.action == .nextDisplayMaxHeight {
            // Center horizontally (width-clamped to the destination, mirroring
            // CenterCalculation) and take the full usable height of the new display.
            let visibleFrameOfScreen = params.visibleFrameOfScreen
            var rect = params.window.rect
            rect.size.width = min(rect.width, visibleFrameOfScreen.width)
            rect.size.height = visibleFrameOfScreen.height
            rect.origin.x = round((visibleFrameOfScreen.width - rect.width) / 2.0) + visibleFrameOfScreen.minX
            rect.origin.y = visibleFrameOfScreen.minY
            return RectResult(rect)
        }

        if params.lastAction?.action == .maximize && !Defaults.autoMaximize.userDisabled {
            let rectResult = WindowCalculationFactory.maximizeCalculation.calculateRect(params)
            return RectResult(rectResult.rect, resultingAction: .maximize)
        }

        return WindowCalculationFactory.centerCalculation.calculateRect(params)
    }
}
