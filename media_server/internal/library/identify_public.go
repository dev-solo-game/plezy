package library

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"plezy/media_server/internal/applog"
	"plezy/media_server/internal/db"
	"plezy/media_server/internal/metadata"
	"plezy/media_server/internal/storage"
)

type PublicIdentifyRequest struct {
	Title           string `json:"title"`
	Year            *int   `json:"year,omitempty"`
	Kind            string `json:"kind"` // "movie" | "show"
	Filename        string `json:"filename,omitempty"`
	FolderHint      string `json:"folder_hint,omitempty"`
	IsAnime         bool   `json:"is_anime,omitempty"`
	AllowKindChange *bool  `json:"allow_kind_change,omitempty"`
	Lang            string `json:"lang,omitempty"`
	Refresh         bool   `json:"refresh,omitempty"`
}

type PublicIdentifyResult struct {
	Matched       bool           `json:"matched"`
	Kind          string         `json:"kind,omitempty"`
	Source        string         `json:"source,omitempty"`
	BridgedFrom   string         `json:"bridged_from,omitempty"`
	ImpliedSeason int            `json:"implied_season,omitempty"`
	Work          *metadata.Work `json:"work,omitempty"`
}

func looksLikeAnimeHint(paths ...string) bool {
	for _, raw := range paths {
		low := strings.ToLower(strings.TrimSpace(raw))
		if low == "" {
			continue
		}
		for _, kw := range []string{"动漫", "動漫", "动画", "動畫", "番剧", "番劇", "国漫", "國漫", "日漫", "美漫", "卡通", "anime", "bangumi", "cartoon"} {
			if strings.Contains(low, kw) {
				return true
			}
		}
	}
	return false
}

// IdentifyPublic executes the 3-tier TMDB-first + auxiliary bridging recognition
// pipeline strictly in memory without mutating local library tables.
func (sc *Scraper) IdentifyPublic(ctx context.Context, req PublicIdentifyRequest) (PublicIdentifyResult, error) {
	cfg := sc.store.GetServerSettings()
	rawKind := strings.ToLower(strings.TrimSpace(req.Kind))
	kind := db.KindMovie
	if rawKind == db.KindShow || rawKind == "tv" || rawKind == "series" {
		kind = db.KindShow
	}
	allowKindChange := kind == db.KindMovie || rawKind == ""
	if req.AllowKindChange != nil {
		allowKindChange = *req.AllowKindChange
	}

	lang := strings.TrimSpace(req.Lang)
	if lang == "" {
		lang = cfg.ScraperLang
	}

	var parsedFile ParsedName
	if strings.TrimSpace(req.Filename) != "" {
		parsedFile = ParseFileName(storage.BaseName(req.Filename))
	}
	var parsedFolder ParsedFolder
	if strings.TrimSpace(req.FolderHint) != "" {
		parsedFolder = ParseFolderName(strings.TrimSpace(req.FolderHint))
	}

	cleanTitle := strings.TrimSpace(req.Title)
	if cleanTitle == "" {
		cleanTitle = strings.TrimSpace(parsedFile.Title)
	}
	if cleanTitle == "" && parsedFolder.Title != "" && !isGenericCategoryFolder(parsedFolder.Title) {
		cleanTitle = parsedFolder.Title
	}
	if cleanTitle == "" && !isGenericCategoryFolder(req.FolderHint) {
		cleanTitle = strings.TrimSpace(req.FolderHint)
	}

	emb := ExtractEmbeddedExternalIDs(req.Filename, req.FolderHint, req.Title)
	hasAnyEmbedded := emb.TmdbID != "" || emb.ImdbID != "" || emb.TvdbID != "" ||
		emb.DoubanID != "" || emb.BangumiID != "" || emb.AniListID != ""
	if cleanTitle == "" && !hasAnyEmbedded {
		return PublicIdentifyResult{}, fmt.Errorf("%w: title or filename is required", metadata.ErrInvalidInput)
	}

	year := req.Year
	if year == nil && parsedFile.Year != nil {
		year = parsedFile.Year
	}
	if year == nil && parsedFolder.Year != nil {
		year = parsedFolder.Year
	}

	isAnime := req.IsAnime || parsedFile.FansubStyle || looksLikeAnimeHint(req.FolderHint, req.Filename)
	hasTmdb := cfg.TmdbAPIKey != ""
	auxProviders := auxiliaryProvidersOrder(isAnime, cfg)
	if !hasTmdb && (len(auxProviders) == 0 || !cfg.AllowFallbackMetadata) {
		return PublicIdentifyResult{}, metadata.ErrNotConfigured
	}

	var rawTitles []string
	addRaw := func(t string) {
		trimmed := strings.TrimSpace(t)
		if trimmed == "" {
			return
		}
		for _, ex := range rawTitles {
			if strings.EqualFold(ex, trimmed) {
				return
			}
		}
		rawTitles = append(rawTitles, trimmed)
	}
	if custom := ApplyCustomRecognitionWords(cleanTitle, cfg.CustomRecognitionWords); custom != "" {
		addRaw(custom)
	}
	addRaw(cleanTitle)
	if folderTitle := strings.TrimSpace(parsedFolder.Title); folderTitle != "" && !parsedFolder.IsSeasonFolder && !isGenericCategoryFolder(folderTitle) {
		if custom := ApplyCustomRecognitionWords(folderTitle, cfg.CustomRecognitionWords); custom != "" {
			addRaw(custom)
		}
		addRaw(folderTitle)
	} else if folderRaw := strings.TrimSpace(req.FolderHint); folderRaw != "" && !isGenericCategoryFolder(folderRaw) {
		if custom := ApplyCustomRecognitionWords(folderRaw, cfg.CustomRecognitionWords); custom != "" {
			addRaw(custom)
		}
		addRaw(folderRaw)
	}
	if fileTitle := strings.TrimSpace(parsedFile.Title); fileTitle != "" {
		if custom := ApplyCustomRecognitionWords(fileTitle, cfg.CustomRecognitionWords); custom != "" {
			addRaw(custom)
		}
		addRaw(fileTitle)
	}

	synthItem := db.MediaItem{
		ID:    0,
		Kind:  kind,
		Title: cleanTitle,
		Year:  year,
	}

	resolveWorkKind := func(k string) string {
		if k == db.KindShow {
			return db.KindShow
		}
		return db.KindMovie
	}

	bridgeExternalToTMDB := func(externalSource, externalID string, supplement *metadata.Work) (PublicIdentifyResult, bool, error) {
		cand, foundKind, err := sc.meta.FindByExternalID(ctx, externalSource, externalID, synthItem.Kind, lang, req.Refresh)
		if err != nil {
			return PublicIdentifyResult{}, false, err
		}
		if cand == nil {
			return PublicIdentifyResult{}, false, nil
		}
		wKind := resolveWorkKind(foundKind)
		if foundKind == "" {
			wKind = synthItem.Kind
		}
		work, wErr := sc.meta.GetWork(ctx, "tmdb", wKind, cand.ID, lang, req.Refresh)
		if wErr != nil {
			return PublicIdentifyResult{}, false, wErr
		}
		supplementTmdbWork(&work, supplement)
		bridgedFrom := ""
		if supplement != nil {
			bridgedFrom = supplement.Source
		}
		return PublicIdentifyResult{
			Matched:     true,
			Kind:        wKind,
			Source:      "tmdb",
			BridgedFrom: bridgedFrom,
			Work:        &work,
		}, true, nil
	}

	var bestStandalone *metadata.Work
	bestStandaloneKind := synthItem.Kind
	bestStandaloneSeason := 0

	if hasTmdb {
		// Embedded TMDB / IMDb / TVDB shortcut
		if emb.TmdbID != "" {
			wKind := synthItem.Kind
			work, err := sc.meta.GetWork(ctx, "tmdb", wKind, emb.TmdbID, lang, req.Refresh)
			if err != nil && allowKindChange {
				altKind := db.KindShow
				if wKind == db.KindShow {
					altKind = db.KindMovie
				}
				if w2, err2 := sc.meta.GetWork(ctx, "tmdb", altKind, emb.TmdbID, lang, req.Refresh); err2 == nil {
					work = w2
					wKind = altKind
					err = nil
				} else if errors.Is(err2, metadata.ErrTmdbUpstream) {
					return PublicIdentifyResult{}, err2
				}
			}
			if err != nil {
				if errors.Is(err, metadata.ErrTmdbUpstream) {
					return PublicIdentifyResult{}, err
				}
			} else {
				return PublicIdentifyResult{
					Matched: true,
					Kind:    wKind,
					Source:  "tmdb",
					Work:    &work,
				}, nil
			}
		}
		if emb.ImdbID != "" {
			if out, ok, err := bridgeExternalToTMDB("imdb_id", emb.ImdbID, nil); err != nil {
				if errors.Is(err, metadata.ErrTmdbUpstream) {
					return PublicIdentifyResult{}, err
				}
			} else if ok {
				return out, nil
			}
		}
		if emb.TvdbID != "" {
			if out, ok, err := bridgeExternalToTMDB("tvdb_id", emb.TvdbID, nil); err != nil {
				if errors.Is(err, metadata.ErrTmdbUpstream) {
					return PublicIdentifyResult{}, err
				}
			} else if ok {
				return out, nil
			}
		}

		// Tier 1: Direct TMDB Search (abort immediately on any TMDB failure)
		matchRes, matchedKind, err := sc.matchOnProviderWithKindPolicy(ctx, "tmdb", synthItem, rawTitles, nil, lang, req.Refresh, allowKindChange)
		if err != nil {
			return PublicIdentifyResult{}, err
		}
		if matchRes != nil {
			wKind := resolveWorkKind(matchedKind)
			if matchedKind == "" {
				wKind = synthItem.Kind
			}
			work, wErr := sc.meta.GetWork(ctx, "tmdb", wKind, matchRes.Candidate.ID, lang, req.Refresh)
			if wErr != nil {
				return PublicIdentifyResult{}, wErr
			}
			return PublicIdentifyResult{
				Matched:       true,
				Kind:          wKind,
				Source:        "tmdb",
				ImpliedSeason: matchRes.ImpliedSeason,
				Work:          &work,
			}, nil
		}

		// Tier 2: Auxiliary providers -> Bridge back to TMDB
		for _, auxProv := range auxProviders {
			auxMatch, auxKind, auxWork, ok := sc.lookupAuxCandidateWorkWithKindPolicy(ctx, auxProv, synthItem, rawTitles, lang, req.Refresh, allowKindChange)
			if !ok {
				continue
			}
			auxWorkKind := resolveWorkKind(auxWork.Kind)
			if auxWork.Kind == "" {
				auxWorkKind = resolveWorkKind(auxKind)
			}
			if bestStandalone == nil {
				wCopy := auxWork
				bestStandalone = &wCopy
				bestStandaloneKind = auxWorkKind
				bestStandaloneSeason = auxMatch.ImpliedSeason
			}

			// Bridge 2A: Direct TMDB ID from auxiliary provider
			if auxWork.TmdbID != nil && *auxWork.TmdbID != "" {
				work, wErr := sc.meta.GetWork(ctx, "tmdb", auxWorkKind, *auxWork.TmdbID, lang, req.Refresh)
				if wErr == nil {
					supplementTmdbWork(&work, &auxWork)
					return PublicIdentifyResult{
						Matched:       true,
						Kind:          auxWorkKind,
						Source:        "tmdb",
						BridgedFrom:   auxProv,
						ImpliedSeason: auxMatch.ImpliedSeason,
						Work:          &work,
					}, nil
				}
				if errors.Is(wErr, metadata.ErrTmdbUpstream) {
					return PublicIdentifyResult{}, wErr
				}
			}

			// Bridge 2B: IMDb / TvDb external ID -> TMDB /find
			if auxWork.ImdbID != nil && *auxWork.ImdbID != "" {
				if out, ok, bErr := bridgeExternalToTMDB("imdb_id", *auxWork.ImdbID, &auxWork); bErr != nil {
					if errors.Is(bErr, metadata.ErrTmdbUpstream) {
						return PublicIdentifyResult{}, bErr
					}
				} else if ok {
					out.ImpliedSeason = auxMatch.ImpliedSeason
					return out, nil
				}
			}
			if auxWork.TvdbID != nil && *auxWork.TvdbID != "" {
				if out, ok, bErr := bridgeExternalToTMDB("tvdb_id", *auxWork.TvdbID, &auxWork); bErr != nil {
					if errors.Is(bErr, metadata.ErrTmdbUpstream) {
						return PublicIdentifyResult{}, bErr
					}
				} else if ok {
					out.ImpliedSeason = auxMatch.ImpliedSeason
					return out, nil
				}
			}

			// Bridge 2C: Canonical title / original title / aliases -> re-search TMDB
			bridgeTitles := collectAuxBridgeTitles(auxWork, rawTitles)
			if len(bridgeTitles) > 0 {
				yearHint := year
				if yearHint == nil {
					yearHint = auxWork.Year
				}
				bridgeMatch, bridgeKind, bErr := sc.matchOnProviderWithKindPolicy(ctx, "tmdb", synthItem, bridgeTitles, yearHint, lang, req.Refresh, allowKindChange)
				if bErr != nil {
					return PublicIdentifyResult{}, bErr
				}
				if bridgeMatch != nil {
					wKind := resolveWorkKind(bridgeKind)
					if bridgeKind == "" {
						wKind = synthItem.Kind
					}
					work, wErr := sc.meta.GetWork(ctx, "tmdb", wKind, bridgeMatch.Candidate.ID, lang, req.Refresh)
					if wErr != nil {
						return PublicIdentifyResult{}, wErr
					}
					supplementTmdbWork(&work, &auxWork)
					applog.Infof("scraper", "公开识别跨源片名反查命中 TMDB [%s:%s %q -> tmdb:%s %q]", auxProv, auxWork.ExternalID, auxWork.Title, work.ExternalID, work.Title)
					return PublicIdentifyResult{
						Matched:       true,
						Kind:          wKind,
						Source:        "tmdb",
						BridgedFrom:   auxProv,
						ImpliedSeason: bridgeMatch.ImpliedSeason,
						Work:          &work,
					}, nil
				}
			}
		}

		// Embedded Douban / Bangumi / AniList ID shortcut when text searches missed
		if bestStandalone == nil && (emb.DoubanID != "" || emb.BangumiID != "" || emb.AniListID != "") {
			if embWork := sc.fetchEmbeddedAuxWork(ctx, synthItem.Kind, emb, lang, req.Refresh); embWork != nil {
				if embWork.ImdbID != nil && *embWork.ImdbID != "" {
					if out, ok, bErr := bridgeExternalToTMDB("imdb_id", *embWork.ImdbID, embWork); bErr != nil {
						if errors.Is(bErr, metadata.ErrTmdbUpstream) {
							return PublicIdentifyResult{}, bErr
						}
					} else if ok {
						return out, nil
					}
				}
				bestStandalone = embWork
				bestStandaloneKind = resolveWorkKind(embWork.Kind)
			}
		}

		// Tier 3: Standalone auxiliary fallback
		if bestStandalone != nil && cfg.AllowFallbackMetadata {
			return PublicIdentifyResult{
				Matched:       true,
				Kind:          bestStandaloneKind,
				Source:        bestStandalone.Source,
				ImpliedSeason: bestStandaloneSeason,
				Work:          bestStandalone,
			}, nil
		}
	} else {
		// No TMDB Key configured; rely on auxiliary sources
		for _, auxProv := range auxProviders {
			auxMatch, auxKind, auxWork, ok := sc.lookupAuxCandidateWorkWithKindPolicy(ctx, auxProv, synthItem, rawTitles, lang, req.Refresh, allowKindChange)
			if !ok {
				continue
			}
			wKind := resolveWorkKind(auxWork.Kind)
			if auxWork.Kind == "" {
				wKind = resolveWorkKind(auxKind)
			}
			wCopy := auxWork
			return PublicIdentifyResult{
				Matched:       true,
				Kind:          wKind,
				Source:        auxProv,
				ImpliedSeason: auxMatch.ImpliedSeason,
				Work:          &wCopy,
			}, nil
		}
	}

	return PublicIdentifyResult{Matched: false}, nil
}
