import Foundation

func check(_ chunks: [String], complete: Bool) {
    var boundary = JSONObjectBoundary()
    for chunk in chunks { boundary.append(chunk) }
    precondition(boundary.complete == complete)
}
check(["  {", "\"items\":[{\"name\":\"a } [ b\"}]", "}"], complete: true)
check(["{\"name\":\"a\\", "\"}b\"", "}"], complete: true)
check(["{\"items\":[{}]"], complete: false)
check(["```json\n{}"], complete: true)
check(["Explanation: {}"], complete: false)
check(["{}"], complete: true)
print("PASS: JSON boundary across chunks, nesting, quoted braces, escapes, incomplete objects and non-JSON prefixes")
