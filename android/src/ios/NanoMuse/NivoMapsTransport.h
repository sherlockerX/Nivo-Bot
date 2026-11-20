#import <MapKit/MapKit.h>
#import "NivoMapsRequest.h"

/// 只转换已验证的模式；骑行必须原样交给MapKit，服务不支持时由服务返回错误。
static inline MKDirectionsTransportType NivoMapsTransportType(NivoMapsMode mode) {
    switch (mode) {
        case NivoMapsModeDriving: return MKDirectionsTransportTypeAutomobile;
        case NivoMapsModeWalking: return MKDirectionsTransportTypeWalking;
        case NivoMapsModeTransit: return MKDirectionsTransportTypeTransit;
        case NivoMapsModeCycling: return MKDirectionsTransportTypeCycling;
    }
    return (MKDirectionsTransportType)0;
}
