/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
@testable import Storage
@testable import Sync
import XCTest


// MARK: - The messy way to extend non-protocol generics.

protocol Succeedable {
    var isSuccess: Bool { get }
}

extension Maybe: Succeedable {
}

private extension Deferred where T: Succeedable {
    func succeeded() {
        self.value.isSuccess
    }
}

private extension BrowserDB {
    func assertQueryReturns(query: String, int: Int) {
        XCTAssertEqual(int, self.runQuery(query, args: nil, factory: IntFactory).value.successValue![0])
    }
}

extension Dictionary {
    init<S: SequenceType where S.Generator.Element == Element>(seq: S) {
        self.init()
        for (k, v) in seq {
            self[k] = v
        }
    }
}

class MockUploader: BookmarkStorer {
    var deletions: Set<GUID> = Set<GUID>()
    var added: Set<GUID> = Set<GUID>()

    func applyUpstreamCompletionOp(op: UpstreamCompletionOp) -> Deferred<Maybe<POSTResult>> {
        op.records.forEach { record in
            if record.payload.deleted {
                deletions.insert(record.id)
            } else {
                added.insert(record.id)
            }
        }
        let guids = op.records.map { $0.id }
        let postResult = POSTResult(modified: NSDate.now(), success: guids, failed: [:])
        return deferMaybe(postResult)
    }
}

// Thieved mercilessly from TestSQLiteBookmarks.
private func getBrowserDBForFile(filename: String, files: FileAccessor) -> BrowserDB? {
    let db = BrowserDB(filename: filename, files: files)

    // BrowserTable exists only to perform create/update etc. operations -- it's not
    // a queryable thing that needs to stick around.
    if !db.createOrUpdate(BrowserTable()) {
        return nil
    }
    return db
}

class TestBookmarkTreeMerging: XCTestCase {
    let files = MockFiles()

    override func tearDown() {
        do {
            try self.files.removeFilesInDirectory()
        } catch {
        }
        super.tearDown()
    }

    private func getBrowserDB(name: String) -> BrowserDB? {
        let file = "TBookmarkTreeMerging\(name).db"
        return getBrowserDBForFile(file, files: self.files)
    }

    func getSyncableBookmarks(name: String) -> MergedSQLiteBookmarks? {
        guard let db = self.getBrowserDB(name) else {
            XCTFail("Couldn't get prepared DB.")
            return nil
        }

        return MergedSQLiteBookmarks(db: db)
    }

    func getSQLiteBookmarks(name: String) -> SQLiteBookmarks? {
        guard let db = self.getBrowserDB(name) else {
            XCTFail("Couldn't get prepared DB.")
            return nil
        }

        return SQLiteBookmarks(db: db)
    }

    func dbLocalTree(name: String) -> BookmarkTree? {
        guard let bookmarks = self.getSQLiteBookmarks(name) else {
            XCTFail("Couldn't get bookmarks.")
            return nil
        }

        return bookmarks.treeForLocal().value.successValue
    }

    func localTree() -> BookmarkTree {
        let roots = BookmarkRoots.RootChildren.map { BookmarkTreeNode.Folder(guid: $0, children: []) }
        let places = BookmarkTreeNode.Folder(guid: BookmarkRoots.RootGUID, children: roots)

        var lookup: [GUID: BookmarkTreeNode] = [:]
        var parents: [GUID: GUID] = [:]

        for n in roots {
            lookup[n.recordGUID] = n
            parents[n.recordGUID] = BookmarkRoots.RootGUID
        }
        lookup[BookmarkRoots.RootGUID] = places

        return BookmarkTree(subtrees: [places], lookup: lookup, parents: parents, orphans: Set(), deleted: Set())
    }

    // Our synthesized tree is the same as the one we pull out of a brand new local DB.
    func testLocalTreeAssumption() {
        let constructed = self.localTree()
        let fromDB = self.dbLocalTree("A")
        XCTAssertNotNil(fromDB)
        XCTAssertTrue(fromDB!.isFullyRootedIn(constructed))
        XCTAssertTrue(constructed.isFullyRootedIn(fromDB!))
    }

    // This scenario can never happen in the wild: we'll always have roots.
    func testMergingEmpty() {
        let r = BookmarkTree.emptyTree()
        let m = BookmarkTree.emptyTree()
        let l = BookmarkTree.emptyTree()

        let merger = ThreeWayTreeMerger(local: l, mirror: m, remote: r)
        guard let result = merger.merge().value.successValue else {
            XCTFail("Couldn't merge.")
            return
        }

        XCTAssertTrue(result.isNoOp)
    }

    func testMergingOnlyLocalRoots() {
        let r = BookmarkTree.emptyTree()
        let m = BookmarkTree.emptyTree()
        let l = self.localTree()

        let merger = ThreeWayTreeMerger(local: l, mirror: m, remote: r)
        guard let result = merger.merge().value.successValue else {
            XCTFail("Couldn't merge.")
            return
        }

        // TODO: enable this when basic merging is implemented.
        // XCTAssertFalse(result.isNoOp)
    }

    private func doMerge(bookmarks: MergedSQLiteBookmarks) -> MockUploader {
        let storer = MockUploader()
        let applier = MergeApplier(buffer: bookmarks, storage: bookmarks, client: storer, greenLight: { true })
        applier.go().succeeded()
        return storer
    }

    func testMergingStorageLocalRootsEmptyServer() {
        guard let bookmarks = self.getSyncableBookmarks("B") else {
            XCTFail("Couldn't get bookmarks.")
            return
        }

        XCTAssertTrue(bookmarks.treeForMirror().value.successValue!.isEmpty)
        let edgesBefore = bookmarks.treesForEdges().value.successValue!
        XCTAssertFalse(edgesBefore.local.isEmpty)
        XCTAssertTrue(edgesBefore.buffer.isEmpty)

        doMerge(bookmarks)

        // Now the local contents are replicated into the mirror, and both the buffer and local are empty.
        guard let mirror = bookmarks.treeForMirror().value.successValue else {
            XCTFail("Couldn't get mirror!")
            return
        }

        // TODO: stuff has moved to the mirror.
        /*
        XCTAssertFalse(mirror.isEmpty)
        XCTAssertTrue(mirror.subtrees[0].recordGUID == BookmarkRoots.RootGUID)
        let edgesAfter = bookmarks.treesForEdges().value.successValue!
        XCTAssertTrue(edgesAfter.local.isEmpty)
        XCTAssertTrue(edgesAfter.buffer.isEmpty)
*/
    }

    func testApplyingTwoEmptyFoldersDoesntSmush() {
        guard let bookmarks = self.getSyncableBookmarks("C") else {
            XCTFail("Couldn't get bookmarks.")
            return
        }

        // Insert two identical folders. We mark them with hasDupe because that's the Syncy
        // thing to do.
        let now = NSDate.now()
        let records = [
            BookmarkMirrorItem.folder(BookmarkRoots.MobileFolderGUID, modified: now, hasDupe: false, parentID: BookmarkRoots.RootGUID, parentName: "", title: "Mobile Bookmarks", description: "", children: ["emptyempty01", "emptyempty02"]),
            BookmarkMirrorItem.folder("emptyempty01", modified: now, hasDupe: true, parentID: BookmarkRoots.MobileFolderGUID, parentName: "Mobile Bookmarks", title: "Empty", description: "", children: []),
            BookmarkMirrorItem.folder("emptyempty02", modified: now, hasDupe: true, parentID: BookmarkRoots.MobileFolderGUID, parentName: "Mobile Bookmarks", title: "Empty", description: "", children: []),
        ]

        bookmarks.buffer.applyRecords(records).succeeded()

        bookmarks.buffer.db.assertQueryReturns("SELECT COUNT(*) FROM \(TableBookmarksBuffer)", int: 3)
        bookmarks.buffer.db.assertQueryReturns("SELECT COUNT(*) FROM \(TableBookmarksBufferStructure)", int: 2)

        doMerge(bookmarks)

        guard let mirror = bookmarks.treeForMirror().value.successValue else {
            XCTFail("Couldn't get mirror!")
            return
        }

        // After merge, the buffer and local are empty.
        let edgesAfter = bookmarks.treesForEdges().value.successValue!
        XCTAssertTrue(edgesAfter.local.isEmpty)
        XCTAssertTrue(edgesAfter.buffer.isEmpty)

        // When merged in, we do not smush these two records together!
        XCTAssertFalse(mirror.isEmpty)
        XCTAssertTrue(mirror.subtrees[0].recordGUID == BookmarkRoots.RootGUID)
        XCTAssertNotNil(mirror.find("emptyempty01"))
        XCTAssertNotNil(mirror.find("emptyempty02"))
        XCTAssertTrue(mirror.deleted.isEmpty)
        guard let mobile = mirror.find(BookmarkRoots.MobileFolderGUID) else {
            XCTFail("No mobile folder in mirror.")
            return
        }

        if case let .Folder(_, children) = mobile {
            XCTAssertEqual(children.map { $0.recordGUID }, ["emptyempty01", "emptyempty02"])
        } else {
            XCTFail("Mobile isn't a folder.")
        }
    }

    func testApplyingTwoEmptyFoldersMatchesOnlyOne() {
        guard let bookmarks = self.getSyncableBookmarks("D") else {
            XCTFail("Couldn't get bookmarks.")
            return
        }

        // Insert three identical folders. We mark them with hasDupe because that's the Syncy
        // thing to do.
        let now = NSDate.now()
        let records = [
            BookmarkMirrorItem.folder(BookmarkRoots.MobileFolderGUID, modified: now, hasDupe: false, parentID: BookmarkRoots.RootGUID, parentName: "", title: "Mobile Bookmarks", description: "", children: ["emptyempty01", "emptyempty02", "emptyempty03"]),
            BookmarkMirrorItem.folder("emptyempty01", modified: now, hasDupe: true, parentID: BookmarkRoots.MobileFolderGUID, parentName: "Mobile Bookmarks", title: "Empty", description: "", children: []),
            BookmarkMirrorItem.folder("emptyempty02", modified: now, hasDupe: true, parentID: BookmarkRoots.MobileFolderGUID, parentName: "Mobile Bookmarks", title: "Empty", description: "", children: []),
            BookmarkMirrorItem.folder("emptyempty03", modified: now, hasDupe: true, parentID: BookmarkRoots.MobileFolderGUID, parentName: "Mobile Bookmarks", title: "Empty", description: "", children: []),
        ]

        bookmarks.buffer.applyRecords(records).succeeded()

        bookmarks.buffer.db.assertQueryReturns("SELECT COUNT(*) FROM \(TableBookmarksBuffer)", int: 4)
        bookmarks.buffer.db.assertQueryReturns("SELECT COUNT(*) FROM \(TableBookmarksBufferStructure)", int: 3)

        // Add one matching empty folder locally.
        // Add one by GUID, too. This is the most complex possible case.

        bookmarks.local.db.run("INSERT INTO \(TableBookmarksLocal) (guid, type, title, parentid, parentName, sync_status) VALUES ('emptyempty02', \(BookmarkNodeType.Folder.rawValue), 'Empty', '\(BookmarkRoots.MobileFolderGUID)', 'Mobile Bookmarks', \(SyncStatus.Changed.rawValue))").succeeded()
        bookmarks.local.db.run("INSERT INTO \(TableBookmarksLocal) (guid, type, title, parentid, parentName, sync_status) VALUES ('emptyemptyL0', \(BookmarkNodeType.Folder.rawValue), 'Empty', '\(BookmarkRoots.MobileFolderGUID)', 'Mobile Bookmarks', \(SyncStatus.New.rawValue))").succeeded()
        bookmarks.local.db.run("INSERT INTO \(TableBookmarksLocalStructure) (parent, child, idx) VALUES ('\(BookmarkRoots.MobileFolderGUID)', 'emptyempty02', 0)").succeeded()
        bookmarks.local.db.run("INSERT INTO \(TableBookmarksLocalStructure) (parent, child, idx) VALUES ('\(BookmarkRoots.MobileFolderGUID)', 'emptyemptyL0', 1)").succeeded()

        let storer = doMerge(bookmarks)

        guard let mirror = bookmarks.treeForMirror().value.successValue else {
            XCTFail("Couldn't get mirror!")
            return
        }

        // After merge, the buffer and local are empty.
        let edgesAfter = bookmarks.treesForEdges().value.successValue!
        XCTAssertTrue(edgesAfter.local.isEmpty)
        XCTAssertTrue(edgesAfter.buffer.isEmpty)

        // All of the incoming records exist.
        XCTAssertFalse(mirror.isEmpty)
        XCTAssertTrue(mirror.subtrees[0].recordGUID == BookmarkRoots.RootGUID)
        XCTAssertNotNil(mirror.find("emptyempty01"))
        XCTAssertNotNil(mirror.find("emptyempty02"))
        XCTAssertNotNil(mirror.find("emptyempty03"))

        // The local record that was smushed is not present…
        XCTAssertNil(mirror.find("emptyemptyL0"))

        // … and even though it was marked New, we tried to delete it, just in case.
        XCTAssertTrue(storer.added.isEmpty)
        XCTAssertTrue(storer.deletions.contains("emptyemptyL0"))

        guard let mobile = mirror.find(BookmarkRoots.MobileFolderGUID) else {
            XCTFail("No mobile folder in mirror.")
            return
        }

        if case let .Folder(_, children) = mobile {
            // This order isn't strictly specified, but try to preserve the remote order if we can.
            XCTAssertEqual(children.map { $0.recordGUID }, ["emptyempty01", "emptyempty02", "emptyempty03"])
        } else {
            XCTFail("Mobile isn't a folder.")
        }
    }

    // TODO: this test should be extended to also exercise the case of a conflict.
    func testLocalRecordsKeepTheirFavicon() {
        guard let bookmarks = self.getSyncableBookmarks("E") else {
            XCTFail("Couldn't get bookmarks.")
            return
        }

        bookmarks.buffer.db.assertQueryReturns("SELECT COUNT(*) FROM \(TableBookmarksBuffer)", int: 0)
        bookmarks.buffer.db.assertQueryReturns("SELECT COUNT(*) FROM \(TableBookmarksBufferStructure)", int: 0)

        bookmarks.local.db.run("INSERT INTO \(TableFavicons) (id, url, width, height, type, date) VALUES (11, 'http://example.org/favicon.ico', 16, 16, 0, \(NSDate.now()))").succeeded()
        bookmarks.local.db.run("INSERT INTO \(TableBookmarksLocal) (guid, type, title, parentid, parentName, sync_status, bmkUri, faviconID) VALUES ('somebookmark', \(BookmarkNodeType.Bookmark.rawValue), 'Some Bookmark', '\(BookmarkRoots.MobileFolderGUID)', 'Mobile Bookmarks', \(SyncStatus.New.rawValue), 'http://example.org/', 11)").succeeded()
        bookmarks.local.db.run("INSERT INTO \(TableBookmarksLocalStructure) (parent, child, idx) VALUES ('\(BookmarkRoots.MobileFolderGUID)', 'somebookmark', 0)").succeeded()

        let storer = doMerge(bookmarks)

        // After merge, the buffer and local are empty.
        let edgesAfter = bookmarks.treesForEdges().value.successValue!
        XCTAssertTrue(edgesAfter.local.isEmpty)
        XCTAssertTrue(edgesAfter.buffer.isEmpty)

        // New record was uploaded.
        XCTAssertTrue(storer.added.contains("somebookmark"))
        XCTAssertTrue(storer.deletions.isEmpty)

        // New record still has its icon ID in the local DB.
        bookmarks.local.db.assertQueryReturns("SELECT faviconID FROM \(TableBookmarksMirror) WHERE bmkUri = 'http://example.org/'", int: 11)
    }
}
