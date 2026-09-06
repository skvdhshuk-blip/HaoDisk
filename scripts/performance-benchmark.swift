// Compile with Core/*.swift, UI/DiskModel.swift and UI/MapLayout.swift using swiftc -O.
import Foundation
import Darwin
@main struct Benchmark {
 static func timings(_ count: Int, _ body: () throws -> Void) rethrows -> [Double] {
  try (0..<count).map { _ in let start = DispatchTime.now().uptimeNanoseconds; try body(); return Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000 }
 }
 static func flat(_ count: Int) -> DiskSnapshot {
  let root = URL(fileURLWithPath: "/HaoDisk-Benchmark", isDirectory: true)
  let dir = FileIdentity(device: 1, inode: 1, mode: UInt16(S_IFDIR | 0o755), size: 0, modifiedSeconds: 0, modifiedNanos: 0)
  let file = FileIdentity(device: 1, inode: 2, mode: UInt16(S_IFREG | 0o644), size: 4096, modifiedSeconds: 0, modifiedNanos: 0)
  var nodes = [DiskNode(id: 0, url: root, parent: nil, identity: dir, isPackage: false)]
  for i in 1...count { var node = DiskNode(id: i, url: root.appendingPathComponent("document-\((i * 7919) % count)-长名称.txt", isDirectory: false), parent: 0, identity: file, isPackage: false); node.allocatedBytes=Int64(i % 127 + 1)*4096; node.logicalBytes=node.allocatedBytes; nodes.append(node) }
  nodes[0].children = Array(1...count); nodes[0].allocatedBytes=nodes.dropFirst().reduce(0){$0+$1.allocatedBytes}; nodes[0].logicalBytes=nodes[0].allocatedBytes
  return DiskSnapshot(nodes:nodes,issues:[],issueCount:0,stopReason:nil,elapsed:0,totalCapacity:nil,availableCapacity:nil)
 }
 @MainActor static func main() async throws {
  var report:[String:Any]=[:]
  var checksum = 0
  for count in [12000,100000] {
   let scan = flat(count)
   let cache = DirectoryCache()
   var cold:[Double]=[]
   for _ in 0..<3 {
    await cache.reset()
    let start=DispatchTime.now().uptimeNanoseconds
    let value=try await cache.value(for:scan,directoryID:0,metric:.allocated,sort:.nameAscending)
    cold.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000)
    checksum += value.rowIDs.count
   }
   report["cold_prepare_\(count)_ms"]=cold
   var hits:[Double]=[]
   for _ in 0..<100 {
    let start=DispatchTime.now().uptimeNanoseconds
    let value=try await cache.value(for:scan,directoryID:0,metric:.allocated,sort:.nameAscending)
    checksum += value.rowIDs.count
    hits.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000)
   }
   report["cached_directory_\(count)_ms"]=hits
   let model=DiskModel()
   await model.install(try PreparedScan.prepare(scan,metric:.allocated,sort:.nameAscending))
   report["selection_\(count)_ms"]=timings(1000) {
    model.selectOffset(1)
    checksum += model.selectedCleanupReason?.count ?? 0
    checksum += model.presentation?.rowByID[model.selectedID ?? 0] ?? 0
   }
   let layout=MapLayoutModel()
   let map=model.presentation!.map
   let size=CGSize(width:700,height:650)
   layout.update(map,size:size)
   report["map_reuse_\(count)_ms"]=timings(1000){layout.update(map,size:size);checksum += layout.tiles.count}
   report["map_layouts_after_1000_reuses_\(count)"]=layout.layoutCount
   var width=700
   report["map_resize_\(count)_ms"]=timings(100){width += 1;layout.update(map,size:CGSize(width:width,height:650))}
  }
  if let path = CommandLine.arguments.dropFirst().first {
  let scan=try DiskScanner().scan(URL(fileURLWithPath:path))
  guard let target=scan.nodes.first(where: {$0.name=="target" && $0.parent==0}) else { throw CleanupError.refused("实测目录必须包含 target 子目录。") }
  report["real_nodes"]=scan.nodes.count; report["target_descendants"]=target.descendantCount
  let model=DiskModel()
  await model.install(try PreparedScan.prepare(scan,metric:.allocated,sort:.sizeDescending))
  report["target_selection_ms"]=timings(1000) {
   model.selectedID = target.id
   checksum += model.selectedCleanupReason?.count ?? 0
   checksum += model.presentation?.rowByID[target.id] ?? 0
  }
  model.navigate(target.id); await model.waitForDirectory()
  model.back(); await model.waitForDirectory()
  var switches:[Double]=[]
  for i in 0..<100 {
   let start=DispatchTime.now().uptimeNanoseconds
   if i % 2 == 0 {model.forward()} else {model.back()}
   await model.waitForDirectory()
   checksum += model.currentID
   switches.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000)
  }
  report["real_cached_model_navigation_ms"]=switches
  }
  report["checksum"]=checksum
  print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
