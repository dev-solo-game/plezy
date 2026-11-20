package pathutil

import "testing"

func TestNormalizeAndHelpers(t *testing.T) {
	cases := []struct {
		raw  string
		want string
	}{
		{"", "/"},
		{"/", "/"},
		{`  \Movies\2026\..\Dune.mkv  `, "/Movies/Dune.mkv"},
		{"/../../secret/passwd.txt", "/secret/passwd.txt"},
		{"a/./b//c/", "/a/b/c"},
	}
	for _, tc := range cases {
		if got := NormalizePath(tc.raw); got != tc.want {
			t.Fatalf("NormalizePath(%q) = %q, want %q", tc.raw, got, tc.want)
		}
	}

	if got := ParentPath("/Movies/Dune.mkv"); got != "/Movies" {
		t.Fatalf("ParentPath = %q", got)
	}
	if got := ParentPath("/Dune.mkv"); got != "/" {
		t.Fatalf("ParentPath root child = %q", got)
	}
	if got := ParentPath("/"); got != "/" {
		t.Fatalf("ParentPath root = %q", got)
	}
	if got := BaseName("/Movies/Dune.MKV"); got != "Dune.MKV" {
		t.Fatalf("BaseName = %q", got)
	}
	if got := BaseName("/"); got != "" {
		t.Fatalf("BaseName root = %q", got)
	}
	if got := ExtLower("/Movies/Dune.MKV"); got != "mkv" {
		t.Fatalf("ExtLower = %q", got)
	}
	if got := ExtLower("/Movies/.hidden"); got != "" {
		t.Fatalf("ExtLower hidden = %q", got)
	}
	if got := JoinPath("/Movies", "Season 1/ep01.mp4"); got != "/Movies/Season 1/ep01.mp4" {
		t.Fatalf("JoinPath = %q", got)
	}
}

func TestPathFilters(t *testing.T) {
	inc, exc := PathFilterFromConfig(map[string]any{
		"includePaths": []any{"/Movies", "/Anime/2026"},
		"excludePaths": []any{"/Movies/Temp"},
	})
	if !CanTraverseDir("/", inc, exc) {
		t.Fatal("root must always be traversable")
	}
	if !CanTraverseDir("/Anime", inc, exc) {
		t.Fatal("ancestor of include path must be traversable")
	}
	if CanTraverseDir("/Movies/Temp", inc, exc) {
		t.Fatal("excluded folder must not be traversable")
	}
	if CanTraverseDir("/Other", inc, exc) {
		t.Fatal("unrelated folder should not be traversable")
	}
	if !IsFileAllowed("/Movies/Dune.mkv", inc, exc) {
		t.Fatal("file under include path should be allowed")
	}
	if IsFileAllowed("/Movies/Temp/sample.mkv", inc, exc) {
		t.Fatal("file under excluded path should not be allowed")
	}
}
