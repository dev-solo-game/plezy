package library

import (
	"fmt"
	"strings"

	"plezy/media_library/internal/db"
)

const numberedSiblingThreshold = 3

type ClassifiedVideo struct {
	Kind         string // movie | episode | ""
	Title        string
	Year         *int
	Season       *int
	Episode      *int
	VersionLabel string
}

func (c ClassifiedVideo) IsKnown() bool {
	return c.Kind != ""
}

func (c ClassifiedVideo) Key() string {
	if !c.IsKnown() {
		return ""
	}
	return fmt.Sprintf("%s|%s|%s|%s|%s",
		c.Kind,
		strings.ToLower(c.Title),
		FormatIntPtr(c.Year),
		FormatIntPtr(c.Season),
		FormatIntPtr(c.Episode),
	)
}

func ClassifyVideo(file ParsedName, folders []ParsedFolder, numberedSiblings int) ClassifiedVideo {
	label := buildVersionLabel(file)
	inSeasonFolder := len(folders) > 0 && folders[0].IsSeasonFolder

	var titleFolder *ParsedFolder
	for i := range folders {
		if !folders[i].IsSeasonFolder && folders[i].Title != "" {
			titleFolder = &folders[i]
			break
		}
	}
	var folderSeason *int
	if inSeasonFolder {
		folderSeason = folders[0].Season
	} else if titleFolder != nil {
		folderSeason = titleFolder.Season
	}

	var number *int
	if file.Episode != nil {
		number = file.Episode
	} else if file.LooseEpisode != nil {
		number = file.LooseEpisode
	} else if file.IsSpecial {
		one := 1
		number = &one
	}

	marked := file.Episode != nil || file.IsSpecial
	looseTrusted := file.LooseEpisode != nil &&
		(file.Season != nil || inSeasonFolder || file.FansubStyle || numberedSiblings >= numberedSiblingThreshold)
	isEpisode := marked || looseTrusted

	if isEpisode {
		title := file.Title
		if title == "" && titleFolder != nil {
			title = titleFolder.Title
		}
		if title == "" || number == nil {
			return ClassifiedVideo{VersionLabel: label}
		}
		seasonNum := 1
		if file.IsSpecial {
			seasonNum = 0
		} else if file.Season != nil {
			seasonNum = *file.Season
		} else if folderSeason != nil {
			seasonNum = *folderSeason
		}
		var showYear *int
		if titleFolder != nil {
			showYear = titleFolder.Year
		}
		return ClassifiedVideo{
			Kind:         db.KindEpisode,
			Title:        title,
			Year:         showYear,
			Season:       &seasonNum,
			Episode:      number,
			VersionLabel: label,
		}
	}

	title := file.Title
	if title == "" && titleFolder != nil {
		title = titleFolder.Title
	}
	if title == "" {
		return ClassifiedVideo{VersionLabel: label}
	}
	year := file.Year
	if year == nil && titleFolder != nil && (file.Title == "" || titleFolder.Title == file.Title) {
		year = titleFolder.Year
	}
	return ClassifiedVideo{
		Kind:         db.KindMovie,
		Title:        title,
		Year:         year,
		VersionLabel: label,
	}
}

func buildVersionLabel(file ParsedName) string {
	var parts []string
	if file.Resolution != "" {
		parts = append(parts, file.Resolution)
	}
	if file.HDR != "" {
		parts = append(parts, file.HDR)
	}
	if file.Edition != "" {
		parts = append(parts, file.Edition)
	}
	return strings.Join(parts, " · ")
}
