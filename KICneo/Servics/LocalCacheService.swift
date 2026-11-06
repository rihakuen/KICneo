import Foundation

/// 以前の Supabase の説明会のキャッシュ（「気になる」を引き継ぐために読むだけ）。
class LocalCacheService {
  private let cacheFileName = "events_cache.json"
    
  private var cacheFileURL: URL {
    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    return paths[0].appendingPathComponent(cacheFileName)
  }
    
  /// 保存する（上書き）
  func save(data: Data) {
    do {
      try data.write(to: cacheFileURL)
      #if DEBUG
      print("[Storage] 保存しました")
      #endif
    } catch {
      #if DEBUG
      print("[Storage] 保存できませんでした: \(error.localizedDescription)")
      #endif
    }
  }
    
  /// 読み込む。ファイルが無ければ nil
  func load() -> Data? {
    do {
      let data = try Data(contentsOf: cacheFileURL)
      #if DEBUG
      print("[Storage] 読み込みました")
      #endif
      return data
    } catch {

      return nil
    }
  }
}
