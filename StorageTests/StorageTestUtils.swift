/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// Note that this file is imported into SyncTests, too.

import Foundation
import Shared
@testable import Storage
import XCTest


// MARK: - The messy way to extend non-protocol generics.

protocol Succeedable {
    var isSuccess: Bool { get }
}

extension Maybe: Succeedable {
}

extension Deferred where T: Succeedable {
    func succeeded() {
        XCTAssertTrue(self.value.isSuccess)
    }
}

extension BrowserDB {
    func assertQueryReturns(query: String, int: Int) {
        XCTAssertEqual(int, self.runQuery(query, args: nil, factory: IntFactory).value.successValue![0])
    }
}

extension BrowserDB {
    func moveLocalToMirrorForTesting() {
        // This is a risky process -- it's not the same logic that the real synchronizer uses
        // (because I haven't written it yet), so it might end up lying. We do what we can.
        let overrideSQL = "INSERT OR IGNORE INTO \(TableBookmarksMirror) " +
                          "(guid, type, bmkUri, title, parentid, parentName, feedUri, siteUri, pos," +
                          " description, tags, keyword, folderName, queryId, " +
                          " is_overridden, server_modified, faviconID) " +
                          "SELECT guid, type, bmkUri, title, parentid, parentName, " +
                          "feedUri, siteUri, pos, description, tags, keyword, folderName, queryId, " +
                          "0 AS is_overridden, \(NSDate.now()) AS server_modified, faviconID " +
                          "FROM \(TableBookmarksLocal)"

        // Copy its mirror structure.
        let copySQL = "INSERT INTO \(TableBookmarksMirrorStructure) " +
                      "SELECT * FROM \(TableBookmarksLocalStructure)"

        // Throw away the old.
        let deleteLocalStructureSQL = "DELETE FROM \(TableBookmarksLocalStructure)"
        let deleteLocalSQL = "DELETE FROM \(TableBookmarksLocal)"

        self.run([
            overrideSQL,
            copySQL,
            deleteLocalStructureSQL,
            deleteLocalSQL,
        ]).succeeded()
    }
}