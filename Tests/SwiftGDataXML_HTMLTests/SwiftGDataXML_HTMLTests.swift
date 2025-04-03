@testable import SwiftGDataXML_HTML
import XCTest

final class SwiftGDataXMLHTMLTests: XCTestCase {

    func testGDataXMLNodeXPathShouldWork() throws {
        let xml = """
            <doc>
                <node attr="val1"/>
                <node attr="val2"/>
                </doc>
            """

        let doc = try GDataXMLDocument(xmlString: xml)
        let nodes = try doc.nodes(forXPath: "//node[@attr=\"val1\"]")
        XCTAssertEqual(nodes.count, 1, "There should be only one node found")
        guard let xmlElement = nodes.first as? GDataXMLElement else {
            XCTFail("Wrong node type")
            return
        }
        let foundValue = xmlElement.attribute(forName: "attr")?.stringValue()
        XCTAssertEqual(foundValue, "val1")
    }

    func testGDataXMLNodeXPathForHTMLShouldWork() throws {
        let docString = """
            <doc aa>
                <node attr="val1"/>
                <node attr="val2"/>
                <node attr="val3">
                </doc>
            """

        let badDoc = try? GDataXMLDocument(xmlString: docString)
        XCTAssertNil(badDoc, "String is not valid XML, creating document should fail")
        let doc = try GDataXMLDocument(htmlString: docString)
        let nodes = try doc.nodes(forXPath: "//node[@attr=\"val1\"]")
        XCTAssertEqual(nodes.count, 1, "There should be only one node found")
        guard let xmlElement = nodes.first as? GDataXMLElement else {
            XCTFail("Wrong node type")
            return
        }
        let foundValue = xmlElement.attribute(forName: "attr")?.stringValue()
        XCTAssertEqual(foundValue, "val1")
    }

    func testGDataXMLNodeXPathShouldReturnRoot() throws {

        // XML
        var doc = try GDataXMLDocument(xmlString: "<doc/>")
        XCTAssertEqual(try doc.nodes(forXPath: "//doc").count, 1, "1.1: Works, 1.2: Works")
        XCTAssertEqual(try doc.nodes(forXPath: "/doc").count, 1, "1.1: Works, 1.2: Works")
        XCTAssertEqual(try doc.nodes(forXPath: "doc").count, 1, "1.1: Works, 1.2: Fails")

        // HTML
        doc = try GDataXMLDocument(htmlString: "<doc/>")
        XCTAssertEqual(try doc.nodes(forXPath: "//html").count, 1, "1.1: Works, 1.2: Works")
        XCTAssertEqual(try doc.nodes(forXPath: "/html").count, 1, "1.1: Fails, 1.2: Fails")
        XCTAssertEqual(try doc.nodes(forXPath: "html").count, 1, "1.1: Fails, 1.2: Fails")

    }

    /*func testNSCrash() throws {
        let invalidXML = """
            <?xml version="1.0"?> \
                <!DOCTYPE EXAMPLE SYSTEM "example.dtd" [
                <!ENTITY xml "<prefix:node>prefix is indeclared here</prefix:node>">
                                                        ]>
                <EXAMPLE xmlns:prefix="http://example.com">
                &xml;
                </EXAMPLE>
            """
        let doc = try GDataXMLDocument(xmlString: invalidXML)
        guard let rootElement = doc.rootElement() else {
            XCTFail("No root")
            return
        }
        let data = self.read(rootElement)
        XCTAssertNotNil(data)
    }
    
    func read(_ node: GDataXMLNode) -> [String : Any]? {
        var childs: [[String : Any]] = []
        var content: String? = nil
        if node.children()?.count == 1 && (node.children()?[0])?.kind() == .textKind {
            if let children = node.children()?[0] {
                content = "\(children)".trimmingCharacters(in: CharacterSet.whitespaces)
            }
        }
        else {
            node.children()?.forEach { child in
                childs.append(read(child) ?? [:])
            }
        }
        return ["tag": node.name() ?? "", "content": childs.count > 0 ? childs : content != nil ? content! : []]
    }*/

    static var allTests = [
        ("testGDataXMLNodeXPathShouldWork", testGDataXMLNodeXPathShouldWork),
        ("testGDataXMLNodeXPathForHTMLShouldWork", testGDataXMLNodeXPathForHTMLShouldWork),
        ("testGDataXMLNodeXPathShouldReturnRoot", testGDataXMLNodeXPathShouldReturnRoot)
    ]
}
