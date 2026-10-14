package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

const (
	duanjuSiteBaseURL = "https://bfzyapi.com"
	duanjuPageSize    = 20
)

var duanjuCategories = []nativeCategory{
	{ID: "58", Name: "短剧大全"},
	{ID: "68", Name: "反转爽文"},
	{ID: "67", Name: "现代言情"},
	{ID: "66", Name: "穿越年代"},
	{ID: "65", Name: "重生民国"},
	{ID: "71", Name: "都市脑洞"},
	{ID: "69", Name: "女恋总裁"},
	{ID: "70", Name: "闪婚离婚"},
	{ID: "72", Name: "古装仙侠"},
	{ID: "74", Name: "AI漫剧"},
}

var duanjuNumericID = regexp.MustCompile(`^[0-9]{1,16}$`)

type macCMSResponse struct {
	Code      int          `json:"code"`
	Msg       string       `json:"msg"`
	Page      any          `json:"page"`
	PageCount any          `json:"pagecount"`
	Limit     any          `json:"limit"`
	Total     any          `json:"total"`
	List      []macCMSItem `json:"list"`
}

type macCMSItem struct {
	VodID       any    `json:"vod_id"`
	TypeID      any    `json:"type_id"`
	TypeName    string `json:"type_name"`
	VodName     string `json:"vod_name"`
	VodPic      string `json:"vod_pic"`
	VodRemarks  string `json:"vod_remarks"`
	VodContent  string `json:"vod_content"`
	VodYear     string `json:"vod_year"`
	VodDirector string `json:"vod_director"`
	VodActor    string `json:"vod_actor"`
	VodPlayFrom string `json:"vod_play_from"`
	VodPlayURL  string `json:"vod_play_url"`
}

func validDuanjuCategory(category string) bool {
	if category == "" || category == "58" {
		return true
	}
	for _, entry := range duanjuCategories {
		if entry.ID == category {
			return true
		}
	}
	return false
}

func (d *Downloader) fetchDuanjuCategories() []nativeCategory {
	return append([]nativeCategory(nil), duanjuCategories...)
}

func (d *Downloader) fetchDuanjuCatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
	if page < 1 || page > 100000 {
		return nil, false, errors.New("聚合短剧目录页码无效")
	}
	site := d.providerBaseURL(sourceDuanju)
	var endpoint string
	if query != "" {
		endpoint = fmt.Sprintf("%s/api.php/provide/vod/?ac=detail&wd=%s&pg=%d", site, url.QueryEscape(query), page)
	} else {
		catID := category
		if catID == "" {
			catID = "58"
		}
		endpoint = fmt.Sprintf("%s/api.php/provide/vod/?ac=detail&t=%s&pg=%d", site, url.QueryEscape(catID), page)
	}
	body, err := d.fetchProviderText(ctx, endpoint, site+"/")
	if err != nil {
		return nil, false, err
	}
	var res macCMSResponse
	if err := json.Unmarshal([]byte(body), &res); err != nil {
		return nil, false, errors.New("聚合短剧接口返回了无效格式")
	}
	var items []Drama
	for _, item := range res.List {
		id := fmt.Sprintf("%v", item.VodID)
		if !duanjuNumericID.MatchString(id) {
			continue
		}
		name := strings.TrimSpace(item.VodName)
		if name == "" {
			continue
		}
		cover := strings.TrimSpace(item.VodPic)
		items = append(items, Drama{
			ID:           providerDramaID(sourceDuanju, id),
			Source:       sourceDuanju,
			SourceID:     id,
			Title:        truncate(name, 512),
			Name:         truncate(name, 512),
			Cover:        cover,
			CoverURL:     cover,
			ChannelName:  "聚合短剧",
			CategoryName: item.TypeName,
			Remark:       truncate(item.VodRemarks, 64),
			Intro:        truncate(item.VodContent, 2048),
		})
	}
	pageCount := 1
	switch v := res.PageCount.(type) {
	case float64:
		pageCount = int(v)
	case string:
		pageCount, _ = strconv.Atoi(v)
	}
	hasMore := page < pageCount
	return items, hasMore, nil
}

func (d *Downloader) fetchDuanjuDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	if !duanjuNumericID.MatchString(sourceID) {
		return Drama{}, nil, errors.New("短剧 ID 无效")
	}
	site := d.providerBaseURL(sourceDuanju)
	endpoint := fmt.Sprintf("%s/api.php/provide/vod/?ac=detail&ids=%s", site, url.QueryEscape(sourceID))
	body, err := d.fetchProviderText(ctx, endpoint, site+"/")
	if err != nil {
		return Drama{}, nil, err
	}
	var res macCMSResponse
	if err := json.Unmarshal([]byte(body), &res); err != nil || len(res.List) == 0 {
		return Drama{}, nil, errors.New("未找到该剧集详情")
	}
	item := res.List[0]
	name := strings.TrimSpace(item.VodName)
	drama := Drama{
		ID:           providerDramaID(sourceDuanju, sourceID),
		Source:       sourceDuanju,
		SourceID:     sourceID,
		Title:        truncate(name, 512),
		Name:         truncate(name, 512),
		Cover:        strings.TrimSpace(item.VodPic),
		CoverURL:     strings.TrimSpace(item.VodPic),
		ChannelName:  "聚合短剧",
		CategoryName: item.TypeName,
		Remark:       truncate(item.VodRemarks, 64),
		Intro:        truncate(item.VodContent, 2048),
	}
	playSources := strings.Split(item.VodPlayURL, "$$$")
	if len(playSources) == 0 {
		return drama, nil, errors.New("该短剧未提供播放线路")
	}
	playSource := playSources[0]
	for _, src := range playSources {
		if strings.Contains(src, ".m3u8") {
			playSource = src
			break
		}
	}
	var chapters []Chapter
	episodeEntries := strings.Split(playSource, "#")
	for index, entry := range episodeEntries {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		parts := strings.SplitN(entry, "$", 2)
		epTitle := fmt.Sprintf("第%d集", index+1)
		videoURL := ""
		if len(parts) == 2 {
			epTitle = strings.TrimSpace(parts[0])
			videoURL = strings.TrimSpace(parts[1])
		} else {
			videoURL = strings.TrimSpace(parts[0])
		}
		if videoURL == "" {
			continue
		}
		chID := providerChapterID(sourceDuanju, sourceID, fmt.Sprintf("%d", index+1))
		chapters = append(chapters, Chapter{
			ID:             chID,
			Title:          epTitle,
			CurrentEpisode: rawEpisode(index + 1),
			VideoURL:       videoURL,
			PageURL:        videoURL,
			Source:         sourceDuanju,
		})
	}
	return drama, chapters, nil
}

func (d *Downloader) resolveDuanjuMedia(ctx context.Context, task Task) (providerMedia, error) {
	videoURL := strings.TrimSpace(task.Chapter.VideoURL)
	if videoURL == "" {
		source, sourceID, valid := splitProviderDramaID(task.DramaID)
		if !valid || source != sourceDuanju {
			return providerMedia{}, errors.New("短剧任务信息无效")
		}
		_, chapters, err := d.fetchDuanjuDetail(ctx, sourceID)
		if err != nil {
			return providerMedia{}, err
		}
		for _, ch := range chapters {
			if ch.ID == task.Chapter.ID || (ch.EpisodeString(0) != "" && ch.EpisodeString(0) == task.Chapter.EpisodeString(0)) {
				videoURL = ch.VideoURL
				break
			}
		}
	}
	if videoURL == "" {
		return providerMedia{}, errors.New("任务缺少播放地址")
	}
	return providerMedia{
		URL:     videoURL,
		Referer: d.providerBaseURL(sourceDuanju) + "/",
	}, nil
}
