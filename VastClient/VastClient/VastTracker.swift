//
//  VastTracker.swift
//  VastClient
//
//  Created by John Gainfort Jr on 4/6/18.
//  Copyright © 2018 John Gainfort Jr. All rights reserved.
//

import Foundation

public protocol VastTrackerDelegate: AnyObject {
    func adFirstQuartile(vastTracker: VastTracker, ad: VastAd)
    func adMidpoint(vastTracker: VastTracker, ad: VastAd)
    func adThirdQuartile(vastTracker: VastTracker, ad: VastAd)
}

enum TrackerModelType {
    case standAlone
    case adPod
    case adBuffet
}

public struct TrackerModel {
    let type: TrackerModelType
    let vastModel: VastModel
}

public class VastTracker {
    public weak var delegate: VastTrackerDelegate?
    
    public let vastModel: VastModel
    public let adBreak: VMAPAdBreak
    public let totalAds: Int
    public let startTime: Double

    private var trackingStatus: TrackingStatus = .unknown
    private var currentTime = 0.0
    private var comparisonTime: Double {
        if trackProgressCumulatively {
            // playhead
            return max(0.0, floor(currentTime - startTime - completedAdAccumulatedDuration))
        } else {
            return currentTime - startTime
        }
    }
    private var vastAds: [VastAd]
    private let trackerModel: TrackerModel
    private var completedAdAccumulatedDuration = 0.0
    private var currentTrackingCreative: TrackingCreative?
    
    private var adBreakStarted = false
    private let trackProgressCumulatively: Bool    
    
    public init(vastModel: VastModel,
                adBreak: VMAPAdBreak,
                startTime: Double = 0.0,
                supportAdBuffets: Bool = false,
                delegate: VastTrackerDelegate? = nil,
                trackProgressCumulatively: Bool = true) {
        self.startTime = startTime
        self.vastModel = vastModel
        self.adBreak = adBreak
        self.trackerModel = VastTracker.getTrackerModel(from: vastModel)
        self.vastAds = VastTracker.getAds(from: trackerModel)
        self.trackingStatus = .tracking
        self.delegate = delegate
        self.totalAds = self.vastAds.count
        self.trackProgressCumulatively = trackProgressCumulatively
    }

    private static func getTrackerModel(from vastModel: VastModel) -> TrackerModel {
        var includesStandAlone = false
        var includesPod = false

        vastModel.ads.forEach { ad in
            if ad.sequence != nil {
                includesPod = true
            } else {
                includesStandAlone = true
            }
        }
        let type: TrackerModelType
        switch (includesStandAlone, includesPod) {
        case (true, true):
            type = .adBuffet
        case (_ , true):
            type = .adPod
        default:
            type = .standAlone
        }
        return TrackerModel(type: type, vastModel: vastModel)
    }
    
    private static func getAds(from trackerModel: TrackerModel) -> [VastAd] {
        switch trackerModel.type {
        case .standAlone, .adBuffet:
            guard let ad = trackerModel.vastModel.ads.first(where: { $0.creatives.contains(where: { $0.linear != nil }) }) else {
                return []
            }
            return [ad]
        case .adPod:
            return trackerModel.vastModel.ads
                .filter { $0.sequence != nil }
                .filter { $0.creatives.contains(where: { $0.linear != nil })}
                .sorted(by: { $0.sequence ?? 0 < $1.sequence ?? 0 })
        }
    }

    public func updateProgress(time: Double) throws {
        var message = "Cannot update tracking progress."
        guard trackingStatus == .tracking || trackingStatus == .paused else {
            switch trackingStatus {
            case .errored:
                message += "Status is errored"
            case .complete:
                throw TrackingError.unableToUpdateProgressTrackingComplete
            default:
                message += "Status is unknown"
            }
            throw TrackingError.unableToUpdateProgress(msg: message)
        }
        currentTime = time
        
        if trackingStatus == .paused {
            // TODO: vast resume
            trackingStatus = .tracking
        }

//        if currentTrackingCreative == nil {
//            guard let vastAd = vastAds.first,
//                let linearCreative = vastAd.creatives.first?.linear, vastAd.sequence ?? 1 > 0 else {
//                    trackingStatus = .complete
//                    delegate?.adBreakComplete(vastTracker: self)
//                    return
//            }
//
//            currentTrackingCreative = TrackingCreative(creative: linearCreative, vastAd: vastAd)
//        }

        guard var creative = currentTrackingCreative else {
            trackingStatus = .errored
            throw TrackingError.internalError(msg: "Unable to find current creative to track")
        }

        let progressUrls = creative.creative.trackingEvents
            .filter { $0.type == .progress && !$0.tracked && $0.url != nil }
            .filter { event -> Bool in
                if var offset = event.offset {
                    if offset > 0 && offset < 1 {
                        offset = creative.duration * offset
                    }
                    if time >= offset {
                        return true
                    }
                } else {
                    return true
                }
                return false
            }
            .compactMap { $0.url }

        if progressUrls.count > 0 {
            progressUrls.forEach { url in
                guard let idx = creative.creative.trackingEvents.firstIndex(where: { $0.url == url }) else { return }
                creative.creative.trackingEvents[idx].tracked = true
            }
            track(urls: progressUrls, eventName: "PROGRESS")
        }

        guard comparisonTime < creative.duration else {
            return
        }
        
        guard currentTime >= startTime else {
            return
        }
        
//        if !creative.trackedStart {
//            creative.trackedStart = true
//
//            let impressions = creative.vastAd.impressions.compactMap { $0.url }
//            track(urls: impressions, eventName: "IMPRESSIONS")
//            trackEvent(.creativeView, creative: creative)
//            trackEvent(.start, creative: creative)
//            delegate?.adStart(vastTracker: self, ad: creative.vastAd)
//        }
        
        if comparisonTime >= creative.firstQuartile, comparisonTime <= creative.midpoint, !creative.trackedFirstQuartile {
            creative.trackedFirstQuartile = true
            trackEvent(.firstQuartile, creative: creative)
            delegate?.adFirstQuartile(vastTracker: self, ad: creative.vastAd)
        }
        if comparisonTime >= creative.midpoint, comparisonTime <= creative.thirdQuartile, !creative.trackedMidpoint {
            creative.trackedMidpoint = true
            trackEvent(.midpoint, creative: creative)
            delegate?.adMidpoint(vastTracker: self, ad: creative.vastAd)
        }
        if comparisonTime >= creative.thirdQuartile, comparisonTime <= creative.duration, !creative.trackedThirdQuartile {
            creative.trackedThirdQuartile = true
            trackEvent(.thirdQuartile, creative: creative)
            delegate?.adThirdQuartile(vastTracker: self, ad: creative.vastAd)
        }
        
        currentTrackingCreative = creative
    }
    
    public func trackAdBreakStart() {
        adBreak.trackEvent(withType: .breakStart)
    }
    
    public func trackAdBreakEnd() {
        adBreak.trackEvent(withType: .breakEnd)
    }
    
    public func trackAdBreakEvents(withURLs urls: [URL]) {
        adBreak.trackEvents(withUrls: urls)
    }
    
    private func getTrackingCreativeFrom(adId: String) throws -> TrackingCreative {
        guard let vastAd = vastAds.first(where: { $0.id == adId }),
            let linearCreative = vastAd.creatives.first?.linear, vastAd.sequence ?? 1 > 0 else {
                throw TrackingError.noAdFound(withId: adId)
        }
        
        return try TrackingCreative(creative: linearCreative, vastAd: vastAd)
    }
    
    public func trackAdStart(withId id: String) throws {
        let creative = try getTrackingCreativeFrom(adId: id)
        currentTrackingCreative = creative
        
        let impressions = creative.vastAd.impressions.compactMap { $0.url }
        track(urls: impressions, eventName: "IMPRESSIONS")
        trackEvent(.start, .creativeView, creative: creative)
    }
    
    public func trackAdComplete(withId id: String) throws {
        let creative = try getTrackingCreativeFrom(adId: id)
        trackEvent(.complete, creative: creative)
    }
    
    public func finishedPlayback() throws {
//        guard var creative = currentTrackingCreative else {
//            trackingStatus = .errored
//            throw TrackingError.internalError(msg: "Unable to find current creative to track")
//        }
//
//        if !creative.trackedComplete && creative.trackedStart {
//            creative.trackedComplete = true
//            try trackEvent(.complete)
//            delegate?.adComplete(vastTracker: self, ad: creative.vastAd)
//            completedAdAccumulatedDuration += creative.duration
//        }
//
//        try tryToPlayNext()
    }

    public func paused(_ val: Bool) throws {
        try trackEventForCurrentCreative(val ? .pause : .resume)
    }

    public func fullscreen(_ val: Bool) throws {
        let fullScreenTrackingEvent: TrackingEventType = val ? .fullscreen : .exitFullscreen
        let playerExpandTrackingEvent: TrackingEventType = val ? .playerExpand : .playerCollapse
        try trackEventForCurrentCreative(fullScreenTrackingEvent, playerExpandTrackingEvent)
    }

    public func rewind() throws {
        try trackEventForCurrentCreative(.rewind)
    }

    public func muted(_ val: Bool) throws {
        try trackEventForCurrentCreative(val ? .mute : .unmute)
    }
    
//    private func tryToPlayNext() throws {
//        vastAds.removeFirst()
//        currentTrackingCreative = nil
//        if vastAds.count > 0 {
//            if trackProgressCumulatively {
//                try updateProgress(time: currentTime)
//            } else {
//                try updateProgress(time: 0.0)
//            }
//        } else {
//            trackingStatus = .complete
//            delegate?.adBreakComplete(vastTracker: self)
//        }
//    }

//    public func skip() throws {
//        if let creative = currentTrackingCreative {
//            guard let skipOffset = creative.vastAd.creatives.first?.linear?.skipOffset?.toSeconds, skipOffset < comparisonTime else {
//                throw TrackingError.unableToSkipAdAtThisTime
//            }
//            try trackEventForCurrentCreative(.skip)
//            completedAdAccumulatedDuration += creative.duration
//            try tryToPlayNext()
//        } else {
//            throw TrackingError.internalError(msg: "Unable to find current creative to track")
//        }
//    }

    public func acceptedLinearInvitation() throws {
        try trackEventForCurrentCreative(.acceptInvitationLinear)
    }

    public func closed() throws {
        try trackEventForCurrentCreative(.closeLinear)
    }

    public func clicked() throws -> URL? {
        if let trackingCreative = currentTrackingCreative {
            trackClicks(for: trackingCreative)
            
            return trackingCreative.creative.videoClicks.first(where: { $0.type == .clickThrough })?.url
        } else {
            // TODO: determine if this is an error or complete
            throw TrackingError.unableToProvideCreativeClickThroughUrls
        }
    }
    
    public func clickedWithCustomAction() throws -> [URL] {
        if let trackingCreative = currentTrackingCreative {
            trackClicks(for: trackingCreative)
            
            return trackingCreative.creative.videoClicks
                .filter { $0.type == .customClick }
                .compactMap { $0.url }
        } else {
            // TODO: determine if this is an error or complete
            throw TrackingError.unableToProvideCreativeClickThroughUrls
        }
    }
    
    private func trackClicks(for creative: TrackingCreative) {
        let clickUrls = creative.creative.videoClicks
            .filter { $0.type == .clickTracking }
            .compactMap { $0.url }
        track(urls: clickUrls, eventName: "CLICK TRACKING")
    }

    public func error(withReason code: VastErrorCodes?) throws {
        if let creative = currentTrackingCreative {
            let urls = creative.vastAd.errors.map { error -> URL in
                if let c = code {
                    return error.withErrorCode(c)
                }
                return error
            }
            track(urls: urls, eventName: "ERROR")
        } else {
            throw TrackingError.internalError(msg: "Unable to find current creative to track")
        }
    }
    
    /*
     Call ViewableImpression urls depending on type of viewability
     
     Host app has to decide on when to call this function.
 
     The point at which these tracking resource files are pinged depends on the viewability standards against which the publisher is certified or any alternate standards document for the transaction between the publisher and advertiser. At the time of this Vast 4.0 specification release, the Media Ratings Council (MRC) had published video viewability recommendations for counting a video ad view after 50% of the ad's pixels are in view for at least two seconds. Publishers should disclose their process for tracking viewable video impressions.
     */
    public func trackViewability(type: VastViewableImpressionType) throws {
        func viewableImpressionUrls(type: VastViewableImpressionType, viewableImpression: VastViewableImpression) -> [URL] {
            switch type {
            case .viewable:
                return viewableImpression.viewable
            case .notViewable:
                return viewableImpression.notViewable
            case .viewUndetermined:
                return viewableImpression.viewUndetermined
            }
        }
        
        if let creative = currentTrackingCreative, let viewableImpression = creative.vastAd.viewableImpression {
            let urls = viewableImpressionUrls(type: type, viewableImpression: viewableImpression)
            track(urls: urls, eventName: "VIEWABLE IMPRESSION \(type.rawValue.uppercased())")
        } else {
            throw TrackingError.internalError(msg: "Unable to find viewableImpression to track")
        }
    }
    
    private func trackEvent(_ types: TrackingEventType..., creative: TrackingCreative) {
        callTrackingUrlsFor(types: types, creative: creative)
    }
    
    private func trackEventForCurrentCreative(_ types: TrackingEventType...) throws {
        if let creative = currentTrackingCreative {
            callTrackingUrlsFor(types: types, creative: creative)
        } else {
            throw TrackingError.internalError(msg: "Unable to find current creative to track")
        }
    }
    
    private func callTrackingUrlsFor(types: [TrackingEventType], creative: TrackingCreative) {
        types.forEach { trackingEventType in
            let trackingUrls = creative.creative.trackingEvents
                .filter { $0.type == trackingEventType }
                .compactMap { $0.url }
            track(urls: trackingUrls, eventName: trackingEventType.rawValue.uppercased())
        }
    }
}
